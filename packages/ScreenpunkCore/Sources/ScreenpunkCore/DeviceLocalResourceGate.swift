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
    func makeUnifiedRuntimeSeedExact(binding: DeviceBoundRestoredRuntimeBinding, entryID: UUID) throws -> DeviceUnifiedPrivateRuntimeSeed {
        let body = try ProvisioningIntentCodec.decode(binding.plan.canonicalBytes)
        let candidate = try StructuralStoreCodec.envelope(body.candidate)
        guard candidate.snapshot.entries.contains(where: { $0.entryID == entryID }),
            let owner = candidate.snapshot.contentOwner, owner.isWellFormed, owner.role == .controller else { throw ConnectionFailure.permissionRequired }
        return try withScope(journal: binding.journal) { scope, permit in
            let fresh = try self.verifyBoundRestoredBinding(binding, scope: scope, permit: permit)
            let seed = try self.grants.makeBoundRuntimeSeed(binding.grants, plan: binding.plan, packages: fresh,
                owner: owner, entryID: entryID, resourcePermit: permit)
            _ = try self.verifyBoundRestoredBinding(binding, scope: scope, permit: permit)
            return seed
        }
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


/// Fixed native3 private-item command, separate from every Local mutation permit.
final class DeviceNativeGrantPrivateCommandPermit {
    private let read: DeviceLocalResourcePermit
    fileprivate init(_ read: DeviceLocalResourcePermit) { self.read = read }
    func begin(_ instance: ObjectIdentifier) throws { try read.beginRead(instance) }
    func end() { read.endRead() }
}
final class DeviceNativeGrantPrivatePublicationPermit {
    private let transition: DeviceNativeGrantPreparationStore.PendingPrivateAttempt
    fileprivate init(_ transition: DeviceNativeGrantPreparationStore.PendingPrivateAttempt) { self.transition = transition }
    func validate(_ original: DeviceNativeGrantPreparationStore.PendingPrivateAttempt) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        guard transition === original else { throw DeviceLocalResourceGateFailure.invalidScope }
    }
}
/// Nonsecret first private-item anchor only. Original resources remain bound to this exact
/// attempt; it confers no credentials, terminal grant, complete-set admission or runtime access.
final class DeviceNativeGrantPrivateAnchor: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let receipt: DeviceNativeGrantPreparationStore.PrivateAttemptReceipt
    fileprivate let journal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite
    fileprivate let packages: DevicePackageResolutionCheckpoint
    fileprivate let genesis: DeviceStructuralStore.NativeGenesisCheckpoint
    fileprivate let plan: DeviceValidatedNativeProvisioningPlan
    fileprivate init(_ receipt: DeviceNativeGrantPreparationStore.PrivateAttemptReceipt,
        _ journal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite,
        _ packages: DevicePackageResolutionCheckpoint, _ genesis: DeviceStructuralStore.NativeGenesisCheckpoint,
        _ plan: DeviceValidatedNativeProvisioningPlan) {
        operationID = receipt.operationID; self.receipt = receipt; self.journal = journal
        self.packages = packages; self.genesis = genesis; self.plan = plan
    }
}
/// Only fixed native package orchestration can dispatch immutable package effects.
final class DeviceNativePackageCommandPermit {
    private let read: DeviceLocalResourcePermit
    fileprivate init(_ read: DeviceLocalResourcePermit) { self.read = read }
    func begin(_ instance: ObjectIdentifier) throws { try read.beginRead(instance) }
    func end() { read.endRead() }
}
/// Only the fixed native credential orchestration can dispatch credential additions.
final class DeviceNativeGrantTerminalCommandPermit {
    private let read: DeviceLocalResourcePermit
    fileprivate init(_ read: DeviceLocalResourcePermit) { self.read = read }
    func begin(_ instance: ObjectIdentifier) throws { try read.beginRead(instance) }
    func end() { read.endRead() }
}
final class DeviceNativeGrantTerminalPublicationPermit {
    private let transition: DeviceNativeGrantPreparationStore.PendingTerminal
    fileprivate init(_ transition: DeviceNativeGrantPreparationStore.PendingTerminal) { self.transition = transition }
    func validate(_ original: DeviceNativeGrantPreparationStore.PendingTerminal) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        guard transition === original else { throw DeviceLocalResourceGateFailure.invalidScope }
    }
}
/// Genuine native grant terminal only. Original journal/genesis/package evidence remains bound.
/// No structural commit, admission, runtime authority or journal capacity release is inferred.
final class DeviceNativeBoundGrantTerminal: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let journal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite
    fileprivate let genesis: DeviceStructuralStore.NativeGenesisCheckpoint
    fileprivate let resolution: DevicePackageTerminalResolution
    fileprivate let plan: DeviceValidatedNativeProvisioningPlan
    fileprivate let receipt: DeviceNativeGrantPreparationStore.TerminalReceipt
    fileprivate init(_ batch: DeviceNativeBoundPackageBatch, _ receipt: DeviceNativeGrantPreparationStore.TerminalReceipt) {
        journal = batch.anchor.journal; genesis = batch.anchor.genesis; resolution = batch.resolution
        plan = batch.anchor.plan; self.receipt = receipt; operationID = receipt.operationID
    }
    fileprivate init(_ journal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite,
        _ genesis: DeviceStructuralStore.NativeGenesisCheckpoint, _ resolution: DevicePackageTerminalResolution,
        _ plan: DeviceValidatedNativeProvisioningPlan, _ receipt: DeviceNativeGrantPreparationStore.TerminalReceipt) {
        self.journal = journal; self.genesis = genesis; self.resolution = resolution
        self.plan = plan; self.receipt = receipt; operationID = receipt.operationID
    }
}
final class DeviceNativeGrantTerminalRecovery: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let packages: DevicePackagePreparationStore.NativeBatchOriginal
    fileprivate let grants: DeviceNativeGrantPreparationStore.TerminalRecovery
    fileprivate let journal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal
    fileprivate let resources: DeviceNativeGrantRecoveryResources
    fileprivate init(_ packages: DevicePackagePreparationStore.NativeBatchOriginal,
        _ grants: DeviceNativeGrantPreparationStore.TerminalRecovery,
        _ journal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal, _ resources: DeviceNativeGrantRecoveryResources) {
        operationID = grants.operationID; self.packages = packages; self.grants = grants
        self.journal = journal; self.resources = resources
    }
}
final class DeviceNativeCredentialCommandPermit {
    private let read: DeviceLocalResourcePermit
    fileprivate init(_ read: DeviceLocalResourcePermit) { self.read = read }
    func begin(_ instance: ObjectIdentifier) throws { try read.beginRead(instance) }
    func end() { read.endRead() }
}
final class DeviceNativeCredentialPublicationPermit {
    private let transition: DeviceNativeGrantPreparationStore.PendingCredentials
    fileprivate init(_ transition: DeviceNativeGrantPreparationStore.PendingCredentials) { self.transition = transition }
    func validate(_ original: DeviceNativeGrantPreparationStore.PendingCredentials) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        guard transition === original else { throw DeviceLocalResourceGateFailure.invalidScope }
    }
}
/// Credential progress only; original journal/genesis/package evidence is preserved.
/// No grant terminal/head, structural commit, admission or runtime authority is inferred.
final class DeviceNativeBoundCredentialProgress: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let journal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite
    fileprivate let genesis: DeviceStructuralStore.NativeGenesisCheckpoint
    fileprivate let resolution: DevicePackageTerminalResolution
    fileprivate let plan: DeviceValidatedNativeProvisioningPlan
    fileprivate let receipt: DeviceNativeGrantPreparationStore.CredentialReceipt
    fileprivate init(_ batch: DeviceNativeBoundPackageBatch, _ receipt: DeviceNativeGrantPreparationStore.CredentialReceipt) {
        journal = batch.anchor.journal; genesis = batch.anchor.genesis; resolution = batch.resolution
        plan = batch.anchor.plan; self.receipt = receipt; operationID = receipt.operationID
    }
    fileprivate init(_ journal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite,
        _ genesis: DeviceStructuralStore.NativeGenesisCheckpoint, _ resolution: DevicePackageTerminalResolution,
        _ plan: DeviceValidatedNativeProvisioningPlan, _ receipt: DeviceNativeGrantPreparationStore.CredentialReceipt) {
        self.journal = journal; self.genesis = genesis; self.resolution = resolution
        self.plan = plan; self.receipt = receipt; operationID = receipt.operationID
    }
}
final class DeviceNativeCredentialRecovery: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let packages: DevicePackagePreparationStore.NativeBatchOriginal
    fileprivate let grants: DeviceNativeGrantPreparationStore.CredentialRecovery
    fileprivate let journal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal
    fileprivate let resources: DeviceNativeGrantRecoveryResources
    fileprivate init(_ packages: DevicePackagePreparationStore.NativeBatchOriginal,
        _ grants: DeviceNativeGrantPreparationStore.CredentialRecovery,
        _ journal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal, _ resources: DeviceNativeGrantRecoveryResources) {
        operationID = grants.operationID; self.packages = packages; self.grants = grants
        self.journal = journal; self.resources = resources
    }
}
/// Native immutable package batch only. Consumes the antecedent package checkpoint and binds
/// a single final actual-tip snapshot; no credential/terminal/structural/admission authority.
final class DeviceNativeBoundPackageBatch: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let anchor: DeviceNativeGrantPrivateAnchor
    fileprivate let resolution: DevicePackageTerminalResolution
    fileprivate init(_ anchor: DeviceNativeGrantPrivateAnchor, _ resolution: DevicePackageTerminalResolution) {
        operationID = anchor.operationID; self.anchor = anchor; self.resolution = resolution
    }
}
/// Captured original private/journal/package nodes for one explicit recovery, not an ACK.
/// No public construction, secret getter, refreshed antecedent or automatic recovery.
final class DeviceNativePackageBatchRecovery: GrantSecretRedacted {
    let operationID: UUID
    fileprivate let packages: DevicePackagePreparationStore.NativeBatchOriginal
    fileprivate let grants: DeviceNativeGrantPreparationStore.RecoveryCheckpoint
    fileprivate let journal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal
    fileprivate let resources: DeviceNativeGrantRecoveryResources
    fileprivate init(_ packages: DevicePackagePreparationStore.NativeBatchOriginal,
        _ grants: DeviceNativeGrantPreparationStore.RecoveryCheckpoint,
        _ journal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal, _ resources: DeviceNativeGrantRecoveryResources) {
        operationID = grants.operationID; self.packages = packages; self.grants = grants
        self.journal = journal; self.resources = resources
    }
}
/// Test-only opaque pending publication, issued by genuine fixed recovery after scope exit.
/// No construction or mutation capability and no receipt/qualification until exact publish.
final class DeviceNativeDeferredJoinPublication: GrantSecretRedacted {
    fileprivate let issuer: ObjectIdentifier
    fileprivate let transition: DeviceLocalProvisioningIntentStore.NativeJoinTransition
    fileprivate init(_ issuer: ObjectIdentifier, _ transition: DeviceLocalProvisioningIntentStore.NativeJoinTransition) {
        self.issuer = issuer; self.transition = transition
    }
}
/// Native3 fixed initialized four-root private/resource command. Package observations never
/// become archive proof or Cloud admission. Backend/fault seams stay synchronous and nonreentrant
/// under locks; publication occurs only after the complete synchronous scope exits.

/// Fixed native structural dispatch only; a read permit cannot construct this capability.
final class DeviceNativeStructuralCommandPermit {
    private let read:DeviceLocalResourcePermit
    fileprivate init(_ read:DeviceLocalResourcePermit){self.read=read}
    func begin(_ instance:ObjectIdentifier)throws{try read.beginRead(instance)}
    func end(){read.endRead()}
}
final class DeviceNativeStructuralPublicationPermit {
    private let original:DeviceStructuralStore.NativeCommandCapture
    fileprivate init(_ original:DeviceStructuralStore.NativeCommandCapture){self.original=original}
    func requireIdle()throws{try DeviceLocalResourceRegistry.requireIdle()}
}
/// Exact mechanical structural durability only. Not a delivery receipt, admission or capacity release.
final class DeviceNativeStructuralCommitAcknowledgment:GrantSecretRedacted {
    let operationID:UUID
    fileprivate let terminal:DeviceNativeBoundGrantTerminal
    fileprivate let capture:DeviceStructuralStore.NativeCommandCapture
    fileprivate init(_ terminal:DeviceNativeBoundGrantTerminal,_ capture:DeviceStructuralStore.NativeCommandCapture) {
        self.terminal=terminal;self.capture=capture;operationID=capture.operationID
    }
}

/// Durable bytes for the fixed HTTP owner. Not current admission or a live dispatch lease.
final class DeviceNativeActivationRequestReceipt:GrantSecretRedacted {
    let requestID:UUID,requestBytes:Data
    fileprivate let terminal:DeviceNativeBoundGrantTerminal
    fileprivate let receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt
    fileprivate init(_ id:UUID,_ bytes:Data,_ terminal:DeviceNativeBoundGrantTerminal,
        _ receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt){requestID=id;requestBytes=bytes;self.terminal=terminal;self.receipt=receipt}
}
/// Original authorization can be reported after expiry. No time/admission capability is persisted.
final class DeviceNativeRetainedAuthorization:GrantSecretRedacted {
    let requestID:UUID,responseBytes:Data
    fileprivate let request:DeviceNativeActivationRequestReceipt
    fileprivate let receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt
    fileprivate init(_ request:DeviceNativeActivationRequestReceipt,_ bytes:Data,
        _ receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt){self.request=request;requestID=request.requestID;responseBytes=bytes;self.receipt=receipt}
}
final class DeviceNativeOutgoingActivatedReceipt:GrantSecretRedacted {
    let bytes:Data
    fileprivate let completed:DeviceNativeProvisioningCompletionAcknowledgment
    fileprivate let authorization:DeviceNativeRetainedAuthorization
    fileprivate let receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt
    fileprivate init(_ bytes:Data,_ completed:DeviceNativeProvisioningCompletionAcknowledgment,
        _ authorization:DeviceNativeRetainedAuthorization,_ receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt){self.bytes=bytes;self.completed=completed;self.authorization=authorization;self.receipt=receipt}
}
final class DeviceNativeReportedActivatedReceipt:GrantSecretRedacted {
    let receiptID:UUID
    fileprivate let outgoing:DeviceNativeOutgoingActivatedReceipt
    fileprivate let receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt
    fileprivate init(_ id:UUID,_ outgoing:DeviceNativeOutgoingActivatedReceipt,
        _ receipt:DeviceLocalProvisioningIntentStore.NativeHTTPReceipt){receiptID=id;self.outgoing=outgoing;self.receipt=receipt}
}
final class DeviceNativeHTTPCommandPermit {
    private let read:DeviceLocalResourcePermit
    fileprivate init(_ read:DeviceLocalResourcePermit){self.read=read}
    func begin(_ instance:ObjectIdentifier)throws{try read.beginRead(instance)}
    func end(){read.endRead()}
}
final class DeviceNativeHTTPPublicationPermit {
    private let original:DeviceLocalProvisioningIntentStore.NativeHTTPTransition
    fileprivate init(_ original:DeviceLocalProvisioningIntentStore.NativeHTTPTransition){self.original=original}
    func validate(_ transition:DeviceLocalProvisioningIntentStore.NativeHTTPTransition)throws {
        guard transition === original else{throw DeviceLocalResourceGateFailure.invalidScope}
        try DeviceLocalResourceRegistry.requireIdle()
    }
}

/// Fixed journal completion capability issued only by this file's four-root orchestration.
final class DeviceNativeCompletionCommandPermit {
    private let read:DeviceLocalResourcePermit
    fileprivate init(_ read:DeviceLocalResourcePermit){self.read=read}
    func begin(_ instance:ObjectIdentifier)throws{try read.beginRead(instance)}
    func end(){read.endRead()}
}
final class DeviceNativeCompletionPublicationPermit {
    private let original:DeviceLocalProvisioningIntentStore.NativeCompletionTransition
    fileprivate init(_ original:DeviceLocalProvisioningIntentStore.NativeCompletionTransition){self.original=original}
    func validate(_ transition:DeviceLocalProvisioningIntentStore.NativeCompletionTransition)throws {
        guard transition === original else{throw DeviceLocalResourceGateFailure.invalidScope}
        try DeviceLocalResourceRegistry.requireIdle()
    }
}
/// Genuine mechanical completion only. No wire receipt construction, new dispatch admission,
/// original authorization, runtime or migration can be inferred from this acknowledgment.
final class DeviceNativeProvisioningCompletionAcknowledgment:GrantSecretRedacted {
    let operationID:UUID
    fileprivate let structural:DeviceNativeStructuralCommitAcknowledgment?
    fileprivate let recovered:DeviceNativeCompletedRecoveryEvidence?
    fileprivate let completion:DeviceLocalProvisioningIntentStore.NativeCompletionReceipt
    fileprivate init(_ structural:DeviceNativeStructuralCommitAcknowledgment,_ completion:DeviceLocalProvisioningIntentStore.NativeCompletionReceipt){self.structural=structural;recovered=nil;self.completion=completion;operationID=structural.operationID}
    fileprivate init(_ recovered:DeviceNativeCompletedRecoveryEvidence,_ completion:DeviceLocalProvisioningIntentStore.NativeCompletionReceipt){structural=nil;self.recovered=recovered;self.completion=completion;operationID=recovered.plan.nativeOperationID}
}

/// Separate native completed-head recovery evidence. No conversion to a NativeJoinReceipt,
/// Local receipt or reconstructed structural ACK; genuine private grant repair remains required.
final class DeviceNativeCompletedResourceRecovery:GrantSecretRedacted {
    fileprivate let journal:DeviceLocalProvisioningIntentStore.NativeCompletionRecoveryOriginal
    fileprivate let grants:DeviceNativeGrantPreparationStore.TerminalRecovery
    fileprivate let packages:DevicePackagePreparationStore.NativeBatchOriginal
    fileprivate let resources:DeviceNativeGrantRecoveryResources
    fileprivate init(_ journal:DeviceLocalProvisioningIntentStore.NativeCompletionRecoveryOriginal,
        _ grants:DeviceNativeGrantPreparationStore.TerminalRecovery,_ packages:DevicePackagePreparationStore.NativeBatchOriginal,
        _ resources:DeviceNativeGrantRecoveryResources){self.journal=journal;self.grants=grants;self.packages=packages;self.resources=resources}
}
fileprivate final class DeviceNativeCompletedRecoveryEvidence:GrantSecretRedacted {
    let plan:DeviceValidatedNativeProvisioningPlan
    let structural:DeviceStructuralStore.NativeCommandCapture
    let grants:DeviceNativeGrantPreparationStore.TerminalReceipt
    let packages:DevicePackageTerminalResolution
    let original:DeviceNativeCompletedResourceRecovery
    init(_ plan:DeviceValidatedNativeProvisioningPlan,_ structural:DeviceStructuralStore.NativeCommandCapture,
         _ grants:DeviceNativeGrantPreparationStore.TerminalReceipt,_ packages:DevicePackageTerminalResolution,
         _ original:DeviceNativeCompletedResourceRecovery){self.plan=plan;self.structural=structural;self.grants=grants;self.packages=packages;self.original=original}
}

final class DeviceNativeGrantPrivateCoordinator {
    private let journal: DeviceLocalProvisioningIntentStore
    private let structural: DeviceStructuralStore
    private let packages: DevicePackagePreparationStore
    private let grants: DeviceNativeGrantPreparationStore
    init(journal: DeviceLocalProvisioningIntentStore, structural: DeviceStructuralStore,
         packages: DevicePackagePreparationStore, grants: DeviceNativeGrantPreparationStore) {
        self.journal = journal; self.structural = structural; self.packages = packages; self.grants = grants
    }
    func prepareExact(_ request: DeviceNativeProvisioningRequest, plan: DeviceValidatedNativeProvisioningPlan,
        joined: DeviceLocalProvisioningIntentStore.NativeJoinReceipt,
        packageResolution: DevicePackageTerminalResolution) throws -> DeviceNativeGrantPrivateAnchor {
        guard request.packages.count <= 12, packageResolution.receipts.count <= 24,
              request.roots.journalID == journal.rootID, request.roots.structuralID == structural.rootID,
              request.roots.packageID == packages.rootID, request.roots.grantID == grants.rootID,
              plan.roots == request.roots else { throw DeviceNativeGrantPreparationError.conflict }
        var pending: DeviceNativeGrantPreparationStore.PendingPrivateAttempt?
        var originalJournal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite?
        do {
            try scope { permit in
                try structural.verifyNativeGenesisExact(request.baseline, resourcePermit: permit)
                let original = try journal.captureNativePrivatePrerequisiteExact(joined, plan: plan, resourcePermit: permit)
                originalJournal = original
                let grantRequest = try checkedRequest(request, plan: plan, resolution: packageResolution, permit: permit)
                try verifyOriginal(request.baseline, journal: original, plan: plan,
                                   packages: packageResolution.checkpoint, permit: permit)
                let transition = try grants.performPrivateAttemptExact(grantRequest, commandPermit: .init(permit))
                pending = transition
                try grants.verifyPendingExact(transition, request: grantRequest, resourcePermit: permit)
                try verifyOriginal(request.baseline, journal: original, plan: plan,
                                   packages: packageResolution.checkpoint, permit: permit)
            }
        } catch {
            if let pending { try grants.discardPrivatePublication(pending) }
            throw error
        }
        guard let pending, let originalJournal else { throw DeviceLocalResourceGateFailure.invalidScope }
        do {
            let receipt = try grants.publishPrivateAttemptExact(pending, publicationPermit: .init(pending))
            return .init(receipt, originalJournal, packageResolution.checkpoint, request.baseline, plan)
        } catch { try grants.discardPrivatePublication(pending); throw error }
    }
    func verifyExact(_ anchor: DeviceNativeGrantPrivateAnchor, request: DeviceNativeProvisioningRequest,
                     packageResolution: DevicePackageTerminalResolution) throws {
        guard request.packages.count <= 12, packageResolution.receipts.count <= 24,
              anchor.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        try scope { permit in
            try verifyOriginal(anchor.genesis, journal: anchor.journal, plan: anchor.plan,
                packages: anchor.packages, permit: permit)
            let fresh = try checkedRequest(request, plan: anchor.plan, resolution: packageResolution, permit: permit)
            try grants.verifyPrivateAttemptExact(anchor.receipt, request: fresh, resourcePermit: permit)
            try verifyOriginal(anchor.genesis, journal: anchor.journal, plan: anchor.plan,
                packages: anchor.packages, permit: permit)
        }
    }
    /// Live package dispatch: the genuine original four-store private anchor is checked before
    /// ANY package epoch/effects. Its package antecedent is then deliberately consumed; only the
    /// returned final batch can describe the newer package tip. No old anchor is renewed.
    func preparePackagesExact(_ request: DeviceNativeProvisioningRequest,
        anchor: DeviceNativeGrantPrivateAnchor) throws -> DeviceNativeBoundPackageBatch {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard anchor.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        var completed: DevicePackageTerminalResolution?
        try scope { permit in
            try verifyOriginal(anchor.genesis, journal: anchor.journal, plan: anchor.plan,
                               packages: anchor.packages, permit: permit)
            let inputs = try packages.inspectNativeBoundPackages(request.packages, plan: anchor.plan, resourcePermit: permit)
            let privateRequest = try nativePackageRequest(request, plan: anchor.plan, inputs: inputs)
            try grants.verifyPrivateAttemptExact(anchor.receipt, request: privateRequest, resourcePermit: permit)
            try verifyOriginal(anchor.genesis, journal: anchor.journal, plan: anchor.plan,
                               packages: anchor.packages, permit: permit)
            let resolution = try packages.performNativeBoundPackagesExact(inputs, plan: anchor.plan, commandPermit: .init(permit))
            let finalInputs = try nativeInputsFromResolution(inputs, resolution: resolution, permit: permit)
            let finalPrivate = try nativePackageRequest(request, plan: anchor.plan, inputs: finalInputs)
            try grants.verifyPrivateAttemptExact(anchor.receipt, request: finalPrivate, resourcePermit: permit)
            try verifyNativeBatchResources(anchor, resolution: resolution, permit: permit)
            completed = resolution
        }
        guard let completed else { throw DeviceLocalResourceGateFailure.invalidScope }
        return .init(anchor, completed)
    }
    func verifyPackageBatchExact(_ batch: DeviceNativeBoundPackageBatch,
        request: DeviceNativeProvisioningRequest) throws {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard batch.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        try scope { permit in
            try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
            let inputs = try nativeInputsFromResolution(request.packages, resolution: batch.resolution, permit: permit)
            let checked = try nativePackageRequest(request, plan: batch.anchor.plan, inputs: inputs)
            try grants.verifyPrivateAttemptExact(batch.anchor.receipt, request: checked, resourcePermit: permit)
            try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
        }
    }
    func credentialReservationSizesForTesting(_ request: DeviceNativeProvisioningRequest,
        batch: DeviceNativeBoundPackageBatch) throws -> [String: Int] {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard batch.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        var sizes: [String: Int]?
        try scope { permit in
            try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
            let inputs = try nativeInputsFromResolution(request.packages, resolution: batch.resolution, permit: permit)
            let fresh = try nativePackageRequest(request, plan: batch.anchor.plan, inputs: inputs)
            try grants.verifyPrivateAttemptExact(batch.anchor.receipt, request: fresh, resourcePermit: permit)
            sizes = try grants.credentialReservationSizesForTesting(fresh, resourcePermit: permit)
            try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
        }
        guard let sizes else { throw DeviceLocalResourceGateFailure.invalidScope }
        return sizes
    }
    func completeCredentialsExact(_ request: DeviceNativeProvisioningRequest,
        batch: DeviceNativeBoundPackageBatch) throws -> DeviceNativeBoundCredentialProgress {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard batch.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        var pending: DeviceNativeGrantPreparationStore.PendingCredentials?
        do {
            try scope { permit in
                try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
                let inputs = try nativeInputsFromResolution(request.packages, resolution: batch.resolution, permit: permit)
                let fresh = try nativePackageRequest(request, plan: batch.anchor.plan, inputs: inputs)
                try grants.verifyPrivateAttemptExact(batch.anchor.receipt, request: fresh, resourcePermit: permit)
                try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
                let transition = try grants.performCredentialsExact(fresh, original: batch.anchor.receipt, commandPermit: .init(permit))
                pending = transition
                try grants.verifyCredentialPendingExact(transition, request: fresh, resourcePermit: permit)
                try verifyNativeBatchResources(batch.anchor, resolution: batch.resolution, permit: permit)
            }
            guard let pending else { throw DeviceLocalResourceGateFailure.invalidScope }
            let receipt = try grants.publishCredentialsExact(pending, publicationPermit: .init(pending))
            return .init(batch, receipt)
        } catch {
            if let pending { try grants.discardCredentialPublication(pending) }
            throw error
        }
    }
    private func verifyCredentialResources(_ progress: DeviceNativeBoundCredentialProgress,
        permit: DeviceLocalResourcePermit) throws {
        try structural.verifyNativeGenesisExact(progress.genesis, resourcePermit: permit)
        try journal.verifyNativePrivatePrerequisiteExact(progress.journal, plan: progress.plan, resourcePermit: permit)
        try packages.verifyResolutionCheckpoint(progress.resolution.checkpoint, resourcePermit: permit)
        guard progress.resolution.receipts.count <= 12 else { throw DeviceNativeGrantPreparationError.sizeLimit }
        for receipt in progress.resolution.receipts { _ = try packages.verify(receipt, resourcePermit: permit) }
    }
    func verifyCredentialProgressExact(_ progress: DeviceNativeBoundCredentialProgress,
        request: DeviceNativeProvisioningRequest) throws {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard progress.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        try scope { permit in
            try verifyCredentialResources(progress, permit: permit)
            let inputs = try nativeInputsFromResolution(request.packages, resolution: progress.resolution, permit: permit)
            let fresh = try nativePackageRequest(request, plan: progress.plan, inputs: inputs)
            try grants.verifyCredentialsExact(progress.receipt, request: fresh, resourcePermit: permit)
            try verifyCredentialResources(progress, permit: permit)
        }
    }
    private func terminalCredentialResources(_ resources: DeviceNativeGrantRecoveryResources) throws -> DeviceNativeGrantRecoveryResources {
        try checkNativeRoots(resources.roots, inputCount: resources.packages.count)
        guard resources.candidate.entries.count <= 12, resources.packages.count == resources.candidate.entries.count else {
            throw DeviceNativeGrantPreparationError.conflict
        }
        // Pure terminal inspection, not synchronization/ACK. Original capture below still checks
        // the complete current inventory under the joint gate and its resolver checks it again.
        let references = resources.candidate.entries.map(\.preparedPackage)
        let verified = try packages.inspectRetainedTerminalExact(references)
        var output: [DeviceProvisioningPackageInput] = []
        var seen = Set<UUID>()
        for input in resources.packages {
            let id: UUID, reference: DevicePreparedPackageReference
            switch input {
            case .supplied(let entry, let operation, let package):
                id = entry
                reference = try PackagePreparationCodec.expectedReference(.init(operationID: operation, package: package), rootID: packages.rootID)
            case .retained(let entry, let given, _): id = entry; reference = given
            }
            guard seen.insert(id).inserted,
                  let entry = resources.candidate.entries.first(where: { $0.entryID == id }),
                  DeviceProvisioningPlanner.exactReference(entry.preparedPackage, reference),
                  let package = verified.first(where: { DeviceProvisioningPlanner.exactReference($0.reference, reference) }) else {
                throw DeviceNativeGrantPreparationError.conflict
            }
            output.append(.retained(entryID: id, reference: reference, verified: package))
        }
        return nativeRecoveryResources(resources, inputs: output)
    }
    func captureCredentialRecoveryExact(operationID: UUID,
        resources: DeviceNativeGrantRecoveryResources) throws -> DeviceNativeCredentialRecovery {
        let terminal = try terminalCredentialResources(resources)
        var originalPackages: DevicePackagePreparationStore.NativeBatchOriginal?
        var originalGrant: DeviceNativeGrantPreparationStore.CredentialRecovery?
        var originalJournal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal?
        var freshResources: DeviceNativeGrantRecoveryResources?
        try scope { permit in
            try structural.verifyNativeGenesisExact(terminal.baseline, resourcePermit: permit)
            let p = try packages.captureNativeBatchOriginal(terminal.packages, candidate: terminal.candidate, resourcePermit: permit)
            let fresh = nativeRecoveryResources(terminal, inputs: p.inputs), expected = nativeExpectations(p.inputs)
            let g = try grants.captureCredentialRecoveryExact(operationID: operationID, resources: fresh,
                expectedEntries: expected, resourcePermit: permit)
            let j = try journal.captureNativeJoinOriginal(g.plan, attachment: nil, resourcePermit: permit)
            try grants.verifyCredentialRecoveryExact(g, resources: fresh, expectedEntries: expected, resourcePermit: permit)
            try packages.verifyNativeBatchOriginal(p, resourcePermit: permit)
            try structural.verifyNativeGenesisExact(terminal.baseline, resourcePermit: permit)
            originalPackages = p; originalGrant = g; originalJournal = j; freshResources = fresh
        }
        guard let originalPackages, let originalGrant, let originalJournal, let freshResources else {
            throw DeviceLocalResourceGateFailure.invalidScope
        }
        return .init(originalPackages, originalGrant, originalJournal, freshResources)
    }
    func completeCredentialsRecoveredExact(_ recovery: DeviceNativeCredentialRecovery) throws -> DeviceNativeBoundCredentialProgress {
        let resources = recovery.resources, plan = recovery.grants.plan
        try checkNativeRoots(resources.roots, inputCount: resources.packages.count)
        let references = resources.candidate.entries.map(\.preparedPackage)
        var j: DeviceLocalProvisioningIntentStore.NativeJoinTransition?
        var g: DeviceNativeGrantPreparationStore.PendingCredentials?
        var prerequisite: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite?
        do {
            // Every original and all terminal/mapping branches precede even journal repair.
            try scope { permit in
                try packages.verifyNativeTerminalBatchOriginal(recovery.packages, references: references, resourcePermit: permit)
                try grants.verifyCredentialRecoveryExact(recovery.grants, resources: resources,
                    expectedEntries: nativeExpectations(resources.packages), resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                let transition = try journal.performNativeJoinExact(plan, original: recovery.journal, commandPermit: .init(permit))
                j = transition
                try journal.verifyNativeJoinTransition(transition, plan: plan, resourcePermit: permit)
                try packages.verifyNativeTerminalBatchOriginal(recovery.packages, references: references, resourcePermit: permit)
                try grants.verifyCredentialRecoveryExact(recovery.grants, resources: resources,
                    expectedEntries: nativeExpectations(resources.packages), resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let j else { throw DeviceLocalResourceGateFailure.invalidScope }
            // Exact original-to-new package repair only. Original grant/genesis and the actual
            // journal transition are retained; no antecedent is refreshed after this unlock.
            let resolution = try packages.resolveRetainedTerminalExact(references, original: recovery.packages)
            var finalResources: DeviceNativeGrantRecoveryResources?
            try scope { permit in
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                let inputs = try nativeInputsFromResolution(resources.packages, resolution: resolution, permit: permit)
                let fresh = nativeRecoveryResources(resources, inputs: inputs), expected = nativeExpectations(inputs)
                finalResources = fresh
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                try grants.verifyCredentialRecoveryExact(recovery.grants, resources: fresh, expectedEntries: expected, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                let transition = try grants.performRecoveredCredentialsExact(recovery.grants, resources: fresh,
                    expectedEntries: expected, commandPermit: .init(permit))
                g = transition
                try grants.verifyRecoveredCredentialsExact(transition, original: recovery.grants, resources: fresh,
                    expectedEntries: expected, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let g, let finalResources else { throw DeviceLocalResourceGateFailure.invalidScope }
            let joined = try journal.publishNativeJoinExact(j, publicationPermit: .init(j))
            try scope { permit in
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                let inputs = try nativeInputsFromResolution(finalResources.packages, resolution: resolution, permit: permit)
                let fresh = nativeRecoveryResources(finalResources, inputs: inputs)
                try grants.verifyRecoveredCredentialsExact(g, original: recovery.grants, resources: fresh,
                    expectedEntries: nativeExpectations(inputs), resourcePermit: permit)
                prerequisite = try journal.captureNativePrivatePrerequisiteExact(joined, plan: plan, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let prerequisite else { throw DeviceLocalResourceGateFailure.invalidScope }
            let receipt = try grants.publishCredentialsExact(g, publicationPermit: .init(g))
            return .init(prerequisite, resources.baseline, resolution, plan, receipt)
        } catch {
            if let g { try grants.discardCredentialPublication(g) }
            if let j { try journal.discardNativeJoinPublication(j) }
            throw error
        }
    }
    /// Read capture ONLY. Package observations precede the original private ref/epoch capture;
    /// both are rechecked jointly. No outside package/journal repair is performed here.
    func capturePackagesRecoveryExact(operationID: UUID,
        resources: DeviceNativeGrantRecoveryResources) throws -> DeviceNativePackageBatchRecovery {
        try checkNativeRoots(resources.roots, inputCount: resources.packages.count)
        var originalPackages: DevicePackagePreparationStore.NativeBatchOriginal?
        try scope { permit in
            try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            originalPackages = try packages.captureNativeBatchOriginal(resources.packages,
                candidate: resources.candidate, resourcePermit: permit)
        }
        guard let originalPackages else { throw DeviceLocalResourceGateFailure.invalidScope }
        let fresh = nativeRecoveryResources(resources, inputs: originalPackages.inputs)
        let expected = nativeExpectations(originalPackages.inputs)
        // No arbitrary callbacks/gate locks held while this ordinary store command enters.
        let originalGrant = try grants.inspectRecoveryExact(operationID: operationID, resources: fresh, expectedEntries: expected)
        var originalJournal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal?
        try scope { permit in
            try packages.verifyNativeBatchOriginal(originalPackages, resourcePermit: permit)
            _ = try packages.inspectNativeBoundPackages(originalPackages.inputs, plan: originalGrant.plan, resourcePermit: permit)
            try grants.verifyRecoveryExact(originalGrant, resources: fresh, expectedEntries: expected, resourcePermit: permit)
            try structural.verifyNativeGenesisExact(fresh.baseline, resourcePermit: permit)
            originalJournal = try journal.captureNativeJoinOriginal(originalGrant.plan, attachment: nil, resourcePermit: permit)
            try packages.verifyNativeBatchOriginal(originalPackages, resourcePermit: permit)
            try grants.verifyRecoveryExact(originalGrant, resources: fresh, expectedEntries: expected, resourcePermit: permit)
        }
        guard let originalJournal else { throw DeviceLocalResourceGateFailure.invalidScope }
        return .init(originalPackages, originalGrant, originalJournal, fresh)
    }
    /// Fixed mapped-pending recovery. Does not call the ordinary terminal-only package resolver
    /// or PR149 journal helper: either would block while package2 has genuine pending evidence.
    func preparePackagesRecoveredExact(_ recovery: DeviceNativePackageBatchRecovery) throws -> DeviceNativeBoundPackageBatch {
        let resources = recovery.resources, plan = recovery.grants.plan
        try checkNativeRoots(resources.roots, inputCount: resources.packages.count)
        var journalPending: DeviceLocalProvisioningIntentStore.NativeJoinTransition?
        var grantPending: DeviceNativeGrantPreparationStore.PendingPrivateAttempt?
        var finalResolution: DevicePackageTerminalResolution?
        var finalResources: DeviceNativeGrantRecoveryResources?
        var originalJournal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite?
        do {
            try scope { permit in
                try packages.verifyNativeBatchOriginal(recovery.packages, resourcePermit: permit)
                let inputs = try packages.inspectNativeBoundPackages(resources.packages, plan: plan, resourcePermit: permit)
                let fresh = nativeRecoveryResources(resources, inputs: inputs), expected = nativeExpectations(inputs)
                try grants.verifyRecoveryExact(recovery.grants, resources: fresh, expectedEntries: expected, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                try packages.verifyNativeBatchOriginal(recovery.packages, resourcePermit: permit)
                // Existing fixed entry validates the ORIGINAL captured journal nodes before its
                // first epoch/sync, after all package and original private-input preflight above.
                let j = try journal.performNativeJoinExact(plan, original: recovery.journal, commandPermit: .init(permit))
                journalPending = j
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try grants.verifyRecoveryExact(recovery.grants, resources: fresh, expectedEntries: expected, resourcePermit: permit)
                try packages.verifyNativeBatchOriginal(recovery.packages, resourcePermit: permit)
                let resolution = try packages.performNativeBoundPackagesExact(inputs, plan: plan, commandPermit: .init(permit))
                finalResolution = resolution
                let finalInputs = try nativeInputsFromResolution(inputs, resolution: resolution, permit: permit)
                let repaired = nativeRecoveryResources(resources, inputs: finalInputs), finalExpected = nativeExpectations(finalInputs)
                finalResources = repaired
                try grants.verifyRecoveryExact(recovery.grants, resources: repaired, expectedEntries: finalExpected, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                let g = try grants.performRecoveredPrivateAttemptExact(recovery.grants, resources: repaired,
                    expectedEntries: finalExpected, commandPermit: .init(permit))
                grantPending = g
                try grants.verifyRecoveredPendingExact(g, original: recovery.grants, resources: repaired,
                    expectedEntries: finalExpected, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let j = journalPending, let g = grantPending,
                  let resolution = finalResolution, let repaired = finalResources else {
                throw DeviceLocalResourceGateFailure.invalidScope
            }
            // Publication permits exist only after the entire FIRST scope exited successfully.
            let joined = try journal.publishNativeJoinExact(j, publicationPermit: .init(j))
            try scope { permit in
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                let finalInputs = try nativeInputsFromResolution(repaired.packages, resolution: resolution, permit: permit)
                let checked = nativeRecoveryResources(repaired, inputs: finalInputs)
                try grants.verifyRecoveredPendingExact(g, original: recovery.grants, resources: checked,
                    expectedEntries: nativeExpectations(finalInputs), resourcePermit: permit)
                originalJournal = try journal.captureNativePrivatePrerequisiteExact(joined, plan: plan, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let originalJournal else { throw DeviceLocalResourceGateFailure.invalidScope }
            // No fresh recapture of the old grant record or epoch: this exact pending object is the
            // deliberate transition from recovery.grants and only now can be published.
            let receipt = try grants.publishPrivateAttemptExact(g, publicationPermit: .init(g))
            let anchor = DeviceNativeGrantPrivateAnchor(receipt, originalJournal, resolution.checkpoint, resources.baseline, plan)
            return .init(anchor, resolution)
        } catch {
            if let grantPending { try grants.discardPrivatePublication(grantPending) }
            if let journalPending { try journal.discardNativeJoinPublication(journalPending) }
            throw error
        }
    }
    /// Narrow deterministic publication regression seam. Performs only the same genuine fixed
    /// journal repair and returns its sealed pending object AFTER whole scope exit; no callbacks,
    /// private bytes, generic command permit or fabricated publication token are exposed.
    func deferRecoveredJournalPublicationForTesting(_ recovery: DeviceNativePackageBatchRecovery) throws -> DeviceNativeDeferredJoinPublication {
        let resources = recovery.resources, plan = recovery.grants.plan
        try checkNativeRoots(resources.roots, inputCount: resources.packages.count)
        var pending: DeviceLocalProvisioningIntentStore.NativeJoinTransition?
        do {
            try scope { permit in
                try packages.verifyNativeBatchOriginal(recovery.packages, resourcePermit: permit)
                let inputs = try packages.inspectNativeBoundPackages(resources.packages, plan: plan, resourcePermit: permit)
                let fresh = nativeRecoveryResources(resources, inputs: inputs)
                try grants.verifyRecoveryExact(recovery.grants, resources: fresh,
                    expectedEntries: nativeExpectations(inputs), resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                let transition = try journal.performNativeJoinExact(plan, original: recovery.journal, commandPermit: .init(permit))
                pending = transition
                try journal.verifyNativeJoinTransition(transition, plan: plan, resourcePermit: permit)
                try grants.verifyRecoveryExact(recovery.grants, resources: fresh,
                    expectedEntries: nativeExpectations(inputs), resourcePermit: permit)
                try packages.verifyNativeBatchOriginal(recovery.packages, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
        } catch { if let pending { try journal.discardNativeJoinPublication(pending) }; throw error }
        guard let pending else { throw DeviceLocalResourceGateFailure.invalidScope }
        return .init(ObjectIdentifier(self), pending)
    }
    func publishDeferredJournalForTesting(_ pending: DeviceNativeDeferredJoinPublication) throws -> DeviceLocalProvisioningIntentStore.NativeJoinReceipt {
        guard pending.issuer == ObjectIdentifier(self) else { throw DeviceLocalResourceGateFailure.invalidScope }
        do { return try journal.publishNativeJoinExact(pending.transition, publicationPermit: .init(pending.transition)) }
        catch { try journal.discardNativeJoinPublication(pending.transition); throw error }
    }
    func discardDeferredJournalForTesting(_ pending: DeviceNativeDeferredJoinPublication) throws {
        guard pending.issuer == ObjectIdentifier(self) else { throw DeviceLocalResourceGateFailure.invalidScope }
        try journal.discardNativeJoinPublication(pending.transition)
    }
    private func checkNativeRoots(_ roots: DeviceProvisioningRoots, inputCount: Int) throws {
        guard inputCount <= 12, roots.journalID == journal.rootID, roots.structuralID == structural.rootID,
              roots.packageID == packages.rootID, roots.grantID == grants.rootID else { throw DeviceNativeGrantPreparationError.conflict }
    }
    private func nativeExpectations(_ inputs: [DeviceProvisioningPackageInput]) -> [DeviceGrantEntryExpectation] {
        inputs.map { input in
            switch input {
            case .supplied(let entryID, _, let package): return .init(entryID: entryID, package: package)
            case .retained(let entryID, _, let verified): return .init(entryID: entryID, package: verified.package)
            }
        }
    }
    private func nativeRecoveryResources(_ original: DeviceNativeGrantRecoveryResources,
        inputs: [DeviceProvisioningPackageInput]) -> DeviceNativeGrantRecoveryResources {
        .init(roots: original.roots, delivery: original.delivery, baseline: original.baseline,
              candidate: original.candidate, packages: inputs)
    }
    private func nativePackageRequest(_ request: DeviceNativeProvisioningRequest, plan: DeviceValidatedNativeProvisioningPlan,
        inputs: [DeviceProvisioningPackageInput]) throws -> DeviceNativeGrantPreparationRequest {
        try checkNativeRoots(request.roots, inputCount: inputs.count)
        let fresh = DeviceNativeProvisioningRequest(roots: request.roots, delivery: request.delivery,
            grantOperationID: request.grantOperationID, baseline: request.baseline, candidate: request.candidate,
            packages: inputs, grantInput: request.grantInput, qualifiedGrant: request.qualifiedGrant)
        let qualified = try DeviceNativeProvisioningPlanner.qualify(fresh)
        guard qualified.intentBytes == plan.intentBytes, qualified.candidateBytes == plan.candidateBytes,
              qualified.delivery.commandBytes == plan.delivery.commandBytes,
              qualified.delivery.planBytes == plan.delivery.planBytes else { throw DeviceNativeGrantPreparationError.conflict }
        return .init(operationID: request.grantOperationID, input: request.grantInput, qualified: request.qualifiedGrant,
                     expectedEntries: nativeExpectations(inputs), plan: plan)
    }
    private func nativeInputsFromResolution(_ inputs: [DeviceProvisioningPackageInput],
        resolution: DevicePackageTerminalResolution, permit: DeviceLocalResourcePermit) throws -> [DeviceProvisioningPackageInput] {
        guard inputs.count <= 12, resolution.receipts.count == inputs.count else { throw DeviceNativeGrantPreparationError.conflict }
        try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
        var output: [DeviceProvisioningPackageInput] = []
        for input in inputs {
            let entryID: UUID, reference: DevicePreparedPackageReference, suppliedOperation: UUID?
            switch input {
            case .supplied(let id, let operation, let package):
                entryID = id; suppliedOperation = operation
                reference = try PackagePreparationCodec.expectedReference(.init(operationID: operation, package: package), rootID: packages.rootID)
            case .retained(let id, let given, _): entryID = id; reference = given; suppliedOperation = nil
            }
            guard let receipt = resolution.receipts.first(where: { DeviceProvisioningPlanner.exactReference($0.reference, reference) }) else {
                throw DeviceNativeGrantPreparationError.conflict
            }
            let verified = try packages.verify(receipt, resourcePermit: permit)
            if let suppliedOperation { output.append(.supplied(entryID: entryID, operationID: suppliedOperation, package: verified.package)) }
            else { output.append(.retained(entryID: entryID, reference: reference, verified: verified)) }
        }
        try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
        return output
    }
    private func verifyNativeBatchResources(_ anchor: DeviceNativeGrantPrivateAnchor,
        resolution: DevicePackageTerminalResolution, permit: DeviceLocalResourcePermit) throws {
        try structural.verifyNativeGenesisExact(anchor.genesis, resourcePermit: permit)
        try journal.verifyNativePrivatePrerequisiteExact(anchor.journal, plan: anchor.plan, resourcePermit: permit)
        try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
        guard resolution.receipts.count <= 12 else { throw DeviceNativeGrantPreparationError.sizeLimit }
        for receipt in resolution.receipts { _ = try packages.verify(receipt, resourcePermit: permit) }
    }
    private func checkedRequest(_ request: DeviceNativeProvisioningRequest, plan: DeviceValidatedNativeProvisioningPlan,
        resolution: DevicePackageTerminalResolution, permit: DeviceLocalResourcePermit) throws -> DeviceNativeGrantPreparationRequest {
        try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
        for receipt in resolution.receipts { _ = try packages.verify(receipt, resourcePermit: permit) }
        var inputs: [DeviceProvisioningPackageInput] = [], expectations: [DeviceGrantEntryExpectation] = []
        for item in request.packages {
            switch item {
            case .supplied(let entryID, let operationID, let package):
                inputs.append(.supplied(entryID: entryID, operationID: operationID, package: package))
                expectations.append(.init(entryID: entryID, package: package))
            case .retained(let entryID, let reference, _):
                guard let receipt = resolution.receipts.first(where: { $0.reference == reference }) else {
                    throw DeviceNativeGrantPreparationError.conflict
                }
                let verified = try packages.verify(receipt, resourcePermit: permit)
                inputs.append(.retained(entryID: entryID, reference: reference, verified: verified))
                expectations.append(.init(entryID: entryID, package: verified.package))
            }
        }
        let freshRequest = DeviceNativeProvisioningRequest(roots: request.roots, delivery: request.delivery,
            grantOperationID: request.grantOperationID, baseline: request.baseline, candidate: request.candidate,
            packages: inputs, grantInput: request.grantInput, qualifiedGrant: request.qualifiedGrant)
        let fresh = try DeviceNativeProvisioningPlanner.qualify(freshRequest)
        guard fresh.intentBytes == plan.intentBytes, fresh.candidateBytes == plan.candidateBytes,
              fresh.delivery.commandBytes == plan.delivery.commandBytes,
              fresh.delivery.planBytes == plan.delivery.planBytes else { throw DeviceNativeGrantPreparationError.conflict }
        return .init(operationID: request.grantOperationID, input: request.grantInput,
            qualified: request.qualifiedGrant, expectedEntries: expectations, plan: plan)
    }
    private func verifyOriginal(_ genesis: DeviceStructuralStore.NativeGenesisCheckpoint,
        journal original: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite,
        plan: DeviceValidatedNativeProvisioningPlan, packages checkpoint: DevicePackageResolutionCheckpoint,
        permit: DeviceLocalResourcePermit) throws {
        try structural.verifyNativeGenesisExact(genesis, resourcePermit: permit)
        try journal.verifyNativePrivatePrerequisiteExact(original, plan: plan, resourcePermit: permit)
        try packages.verifyResolutionCheckpoint(checkpoint, resourcePermit: permit)
    }
    /// Explicit journal repair, preserving the original grant checkpoint across its epoch
    /// transition. No private item is recommitted here and no anchor is issued by diagnosis.
    func recommitJournalForRecoveryExact(_ recovery: DeviceNativeGrantPreparationStore.RecoveryCheckpoint,
        resources: DeviceNativeGrantRecoveryResources, packageResolution: DevicePackageTerminalResolution) throws -> DeviceLocalProvisioningIntentStore.NativeJoinReceipt {
        var pending: DeviceLocalProvisioningIntentStore.NativeJoinTransition?
        do {
            try scope { permit in
                let fresh = try checkedRecoveryResources(resources, resolution: packageResolution, permit: permit)
                try grants.verifyRecoveryExact(recovery, resources: fresh.0, expectedEntries: fresh.1, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                let original = try journal.captureNativeJoinOriginal(recovery.plan, attachment: nil, resourcePermit: permit)
                try grants.verifyRecoveryExact(recovery, resources: fresh.0, expectedEntries: fresh.1, resourcePermit: permit)
                let transition = try journal.performNativeJoinExact(recovery.plan, original: original, commandPermit: .init(permit))
                pending = transition
                try journal.verifyNativeJoinTransition(transition, plan: recovery.plan, resourcePermit: permit)
                try grants.verifyRecoveryExact(recovery, resources: fresh.0, expectedEntries: fresh.1, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(packageResolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
        } catch {
            if let pending { try journal.discardNativeJoinPublication(pending) }
            throw error
        }
        guard let pending else { throw DeviceLocalResourceGateFailure.invalidScope }
        do { return try journal.publishNativeJoinExact(pending, publicationPermit: .init(pending)) }
        catch { try journal.discardNativeJoinPublication(pending); throw error }
    }
    func prepareRecoveredExact(_ recovery: DeviceNativeGrantPreparationStore.RecoveryCheckpoint,
        resources: DeviceNativeGrantRecoveryResources,
        joined: DeviceLocalProvisioningIntentStore.NativeJoinReceipt,
        packageResolution: DevicePackageTerminalResolution) throws -> DeviceNativeGrantPrivateAnchor {
        var pending: DeviceNativeGrantPreparationStore.PendingPrivateAttempt?
        var originalJournal: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite?
        do {
            try scope { permit in
                let fresh = try checkedRecoveryResources(resources, resolution: packageResolution, permit: permit)
                try grants.verifyRecoveryExact(recovery, resources: fresh.0, expectedEntries: fresh.1, resourcePermit: permit)
                let original = try journal.captureNativePrivatePrerequisiteExact(joined, plan: recovery.plan, resourcePermit: permit)
                originalJournal = original
                try verifyOriginal(resources.baseline, journal: original, plan: recovery.plan,
                    packages: packageResolution.checkpoint, permit: permit)
                let transition = try grants.performRecoveredPrivateAttemptExact(recovery, resources: fresh.0,
                    expectedEntries: fresh.1, commandPermit: .init(permit))
                pending = transition
                try grants.verifyRecoveredPendingExact(transition, original: recovery, resources: fresh.0,
                    expectedEntries: fresh.1, resourcePermit: permit)
                try verifyOriginal(resources.baseline, journal: original, plan: recovery.plan,
                    packages: packageResolution.checkpoint, permit: permit)
            }
        } catch {
            if let pending { try grants.discardPrivatePublication(pending) }
            throw error
        }
        guard let pending, let originalJournal else { throw DeviceLocalResourceGateFailure.invalidScope }
        do {
            let receipt = try grants.publishPrivateAttemptExact(pending, publicationPermit: .init(pending))
            return .init(receipt, originalJournal, packageResolution.checkpoint, resources.baseline, recovery.plan)
        } catch { try grants.discardPrivatePublication(pending); throw error }
    }
    private func checkedRecoveryResources(_ resources: DeviceNativeGrantRecoveryResources,
        resolution: DevicePackageTerminalResolution, permit: DeviceLocalResourcePermit) throws -> (DeviceNativeGrantRecoveryResources, [DeviceGrantEntryExpectation]) {
        guard resources.packages.count <= 12, resolution.receipts.count <= 24,
              resources.roots.journalID == journal.rootID, resources.roots.structuralID == structural.rootID,
              resources.roots.packageID == packages.rootID, resources.roots.grantID == grants.rootID else {
            throw DeviceNativeGrantPreparationError.conflict
        }
        try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
        for receipt in resolution.receipts { _ = try packages.verify(receipt, resourcePermit: permit) }
        var inputs: [DeviceProvisioningPackageInput] = [], expected: [DeviceGrantEntryExpectation] = []
        for item in resources.packages {
            switch item {
            case .supplied(let entryID, let operationID, let package):
                inputs.append(.supplied(entryID: entryID, operationID: operationID, package: package))
                expected.append(.init(entryID: entryID, package: package))
            case .retained(let entryID, let reference, _):
                guard let receipt = resolution.receipts.first(where: { $0.reference == reference }) else { throw DeviceNativeGrantPreparationError.conflict }
                let verified = try packages.verify(receipt, resourcePermit: permit)
                inputs.append(.retained(entryID: entryID, reference: reference, verified: verified))
                expected.append(.init(entryID: entryID, package: verified.package))
            }
        }
        return (.init(roots: resources.roots, delivery: resources.delivery, baseline: resources.baseline,
            candidate: resources.candidate, packages: inputs), expected)
    }

    private struct NativeStructuralOutcome:Encodable {
        let schemaVersion:Int,operationID:UUID,generationID:UUID
    }
    private struct NativeStructuralResources:Encodable {
        let journalRootID:UUID,packageRootID:UUID,grantRootID:UUID,grantOperationID:UUID
        let grantIdentity:DeviceGrantRevisionIdentity
    }
    private func nativeStructuralCommand(_ request:DeviceNativeProvisioningRequest,
        terminal:DeviceNativeBoundGrantTerminal,permit:DeviceLocalResourcePermit) throws -> (candidate:Data,assertions:Data,intent:Data,outcome:Data) {
        try checkNativeRoots(request.roots,inputCount:request.packages.count)
        guard request.grantOperationID == terminal.operationID,
              request.delivery.nativeOperationID == terminal.plan.nativeOperationID,
              request.baseline.rootID == structural.rootID else {throw DeviceStructuralStoreError.conflict}
        let inputs=try nativeInputsFromResolution(request.packages,resolution:terminal.resolution,permit:permit)
        let fresh=try nativePackageRequest(request,plan:terminal.plan,inputs:inputs)
        try journal.verifyNativePrivatePrerequisiteExact(terminal.journal,plan:terminal.plan,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(terminal.resolution.checkpoint,resourcePermit:permit)
        for receipt in terminal.resolution.receipts {_ = try packages.verify(receipt,resourcePermit:permit)}
        try grants.verifyTerminalExact(terminal.receipt,request:fresh,resourcePermit:permit)
        try structural.verifyNativeGenesisNodesForDispatch(terminal.genesis,resourcePermit:permit)
        let outcome=try DeviceNativeStructuralCommandCodec.encode(NativeStructuralOutcome(schemaVersion:2,operationID:terminal.plan.nativeOperationID,generationID:request.candidate.generationID),limit:32768)
        let bytes=terminal.plan.candidateBytes
        let envelope=try DeviceNativeStructuralEnvelopeCodec.decode(bytes)
        guard envelope.operationID == terminal.plan.nativeOperationID,
              envelope.expectedGenerationID == terminal.genesis.state.generationID,
              envelope.snapshotBytes == (try DeviceNativeStructuralStateCodec.encode(request.candidate)),
              terminal.plan.intentBytes.count <= 32768 else {throw DeviceStructuralStoreError.conflict}
        let resources=try DeviceNativeStructuralCommandCodec.encode(NativeStructuralResources(journalRootID:request.roots.journalID,packageRootID:request.roots.packageID,grantRootID:request.roots.grantID,grantOperationID:request.grantOperationID,grantIdentity:request.grantInput.identity),limit:8192)
        return(bytes,resources,terminal.plan.intentBytes,outcome)
    }
    func nativeStructuralReservationSizesForTesting(_ request:DeviceNativeProvisioningRequest,
        terminal:DeviceNativeBoundGrantTerminal) throws -> [String:Int] {
        var sizes:[String:Int]?
        try nativeStructuralScope {permit in
            let command=try nativeStructuralCommand(request,terminal:terminal,permit:permit)
            sizes=try structural.nativeDispatchReservationSizesForTesting(candidate:command.candidate,assertions:command.assertions,intent:command.intent,outcome:command.outcome,operationID:terminal.plan.nativeOperationID,resourcePermit:permit)
        }
        guard let sizes else {throw DeviceLocalResourceGateFailure.invalidScope};return sizes
    }
    /// Retained exact method is checked before qualified-current capture inside the fixed store.
    /// Same operation repairs candidate/terminal uncertainty; a different/second operation rejects.
    func commitNativeStructuralExact(_ request:DeviceNativeProvisioningRequest,
        terminal:DeviceNativeBoundGrantTerminal) throws -> DeviceNativeStructuralCommitAcknowledgment {
        var pending:DeviceStructuralStore.NativeCommandCapture?
        do {
            try nativeStructuralScope {permit in
                let before=try nativeStructuralCommand(request,terminal:terminal,permit:permit)
                let capture=try structural.performNativeCommandExact(candidate:before.candidate,assertions:before.assertions,intent:before.intent,outcome:before.outcome,baseline:terminal.genesis,commandPermit:.init(permit))
                pending=capture
                let after=try nativeStructuralCommand(request,terminal:terminal,permit:permit)
                guard before.candidate == after.candidate,before.assertions == after.assertions,before.intent == after.intent,before.outcome == after.outcome else {throw DeviceStructuralStoreError.conflict}
                try structural.verifyNativeCommandCapture(capture,resourcePermit:permit)
            }
            guard let pending else {throw DeviceLocalResourceGateFailure.invalidScope}
            let capture=try structural.publishNativeCommandExact(pending,permit:.init(pending))
            return .init(terminal,capture)
        } catch {
            if let pending {try structural.discardNativeCommandExact(pending)}
            throw error
        }
    }
    func verifyNativeStructuralAcknowledgmentExact(_ original:DeviceNativeStructuralCommitAcknowledgment,
        request:DeviceNativeProvisioningRequest) throws {
        try nativeStructuralScope {permit in
            let command=try nativeStructuralCommand(request,terminal:original.terminal,permit:permit)
            guard command.candidate == original.capture.envelopeBytes,original.operationID == request.delivery.nativeOperationID else {throw DeviceStructuralStoreError.conflict}
            try structural.verifyNativeCommandCapture(original.capture,resourcePermit:permit)
        }
    }

    private func verifyNativeCompletionResources(_ request:DeviceNativeProvisioningRequest,
        original:DeviceNativeStructuralCommitAcknowledgment,permit:DeviceLocalResourcePermit)throws {
        let terminal=original.terminal
        try checkNativeRoots(request.roots,inputCount:request.packages.count)
        guard original.operationID == request.delivery.nativeOperationID,
              request.grantOperationID == terminal.operationID,
              terminal.plan.candidateBytes == original.capture.envelopeBytes else{throw DeviceStructuralStoreError.conflict}
        let inputs=try nativeInputsFromResolution(request.packages,resolution:terminal.resolution,permit:permit)
        let fresh=try nativePackageRequest(request,plan:terminal.plan,inputs:inputs)
        // Original private resources and structural capture are retained; journal alone has
        // an explicitly validated intentional transition. No current checkpoint recapture.
        try journal.verifyNativeCompletionAntecedentsExact(terminal.journal,plan:terminal.plan,
            envelope:original.capture.envelopeBytes,structuralRootID:structural.rootID,resourcePermit:permit)
        try packages.verifyResolutionCheckpoint(terminal.resolution.checkpoint,resourcePermit:permit)
        for receipt in terminal.resolution.receipts {_ = try packages.verify(receipt,resourcePermit:permit)}
        try grants.verifyTerminalExact(terminal.receipt,request:fresh,resourcePermit:permit)
        try structural.verifyNativeCommandCapture(original.capture,resourcePermit:permit)
        let encoded=try DeviceNativeStructuralStateCodec.encode(request.candidate)
        let envelope=try DeviceNativeStructuralEnvelopeCodec.decode(original.capture.envelopeBytes)
        guard envelope.snapshotBytes == encoded,envelope.operationID == request.delivery.nativeOperationID,
              request.delivery.commandBytes == terminal.plan.delivery.commandBytes,
              request.delivery.planBytes == terminal.plan.delivery.planBytes else{throw DeviceStructuralStoreError.conflict}
    }
    /// Genuine resource-bound durable request only. The HTTP owner separately supplies current
    /// authenticated admission; this method neither performs POST nor admits structural dispatch.
    func retainNativeActivationRequestExact(_ request:DeviceNativeProvisioningRequest,
        terminal:DeviceNativeBoundGrantTerminal,requestID:UUID)throws->DeviceNativeActivationRequestReceipt {
        let bytes=try DeviceNativeDeliveryHTTPCodec.activationRequest(binding:request.delivery,requestID:requestID)
        var pending:DeviceLocalProvisioningIntentStore.NativeHTTPTransition?
        do {
            try nativeCompletionScope {permit in
                _ = try nativeStructuralCommand(request,terminal:terminal,permit:permit)
                let transition=try journal.performNativeHTTPExact(terminal.journal,plan:terminal.plan,
                    phase:.activation,requestID:requestID,request:bytes,response:nil,completed:nil,commandPermit:.init(permit))
                pending=transition
                _ = try nativeStructuralCommand(request,terminal:terminal,permit:permit)
                try journal.verifyNativeHTTPTransitionExact(transition,resourcePermit:permit)
            }
            guard let pending else{throw DeviceLocalResourceGateFailure.invalidScope}
            return .init(requestID,bytes,terminal,try journal.publishNativeHTTPExact(pending,publicationPermit:.init(pending)))
        } catch {if let pending{try journal.discardNativeHTTPExact(pending)};throw error}
    }
    /// Exact original response is retained before a future admitted dispatch. Server dates are
    /// historical bytes here; expiry never discards the original reporting association.
    func retainNativeAuthorizationExact(_ request:DeviceNativeProvisioningRequest,
        original:DeviceNativeActivationRequestReceipt,response:Data)throws->DeviceNativeRetainedAuthorization {
        guard response.count <= 4096 else{throw DeviceNativeDeliveryAttachmentCodec.Failure.capacity}
        _ = try DeviceNativeDeliveryHTTPCodec.observe(response,kind:.activationResponse,
            binding:request.delivery,requestID:original.requestID)
        var pending:DeviceLocalProvisioningIntentStore.NativeHTTPTransition?
        do {
            try nativeCompletionScope {permit in
                _ = try nativeStructuralCommand(request,terminal:original.terminal,permit:permit)
                try journal.verifyNativeHTTPExact(original.receipt,resourcePermit:permit)
                let transition=try journal.performNativeHTTPExact(original.terminal.journal,plan:original.terminal.plan,
                    phase:.activation,requestID:original.requestID,request:original.requestBytes,response:response,
                    completed:nil,commandPermit:.init(permit))
                pending=transition
                _ = try nativeStructuralCommand(request,terminal:original.terminal,permit:permit)
                try journal.verifyNativeHTTPTransitionExact(transition,resourcePermit:permit)
            }
            guard let pending else{throw DeviceLocalResourceGateFailure.invalidScope}
            return .init(original,response,try journal.publishNativeHTTPExact(pending,publicationPermit:.init(pending)))
        } catch {if let pending{try journal.discardNativeHTTPExact(pending)};throw error}
    }
    /// Read-only original authorization check. This is not the promotion owner's foreground
    /// admission/monotonic-deadline handle and must never substitute for one.
    func verifyNativeRetainedAuthorizationExact(_ request:DeviceNativeProvisioningRequest,
        original:DeviceNativeRetainedAuthorization)throws {
        try nativeCompletionScope {permit in
            _ = try nativeStructuralCommand(request,terminal:original.request.terminal,permit:permit)
            try journal.verifyNativeHTTPExact(original.receipt,resourcePermit:permit)
            _ = try DeviceNativeDeliveryHTTPCodec.observe(original.responseBytes,kind:.activationResponse,
                binding:request.delivery,requestID:original.requestID)
        }
    }
    private func verifyNativeCompletedForHTTP(_ request:DeviceNativeProvisioningRequest,
        completed:DeviceNativeProvisioningCompletionAcknowledgment,permit:DeviceLocalResourcePermit)throws->DeviceValidatedNativeProvisioningPlan {
        guard completed.operationID == request.delivery.nativeOperationID else{throw DeviceStructuralStoreError.conflict}
        let plan:DeviceValidatedNativeProvisioningPlan
        if let live=completed.structural {
            try verifyNativeCompletionResources(request,original:live,permit:permit);plan=live.terminal.plan
        } else if let recovered=completed.recovered {
            try checkNativeRoots(request.roots,inputCount:request.packages.count)
            let inputs=try nativeInputsFromResolution(request.packages,resolution:recovered.packages,permit:permit)
            let fresh=try nativePackageRequest(request,plan:recovered.plan,inputs:inputs)
            try packages.verifyResolutionCheckpoint(recovered.packages.checkpoint,resourcePermit:permit)
            for receipt in recovered.packages.receipts{_ = try packages.verify(receipt,resourcePermit:permit)}
            try grants.verifyTerminalExact(recovered.grants,request:fresh,resourcePermit:permit)
            try structural.verifyNativeCommandCapture(recovered.structural,resourcePermit:permit)
            guard recovered.structural.envelopeBytes == recovered.plan.candidateBytes,
                  request.delivery.commandBytes == recovered.plan.delivery.commandBytes,
                  request.delivery.planBytes == recovered.plan.delivery.planBytes else{throw DeviceStructuralStoreError.conflict}
            plan=recovered.plan
        } else{throw DeviceLocalResourceGateFailure.invalidScope}
        try journal.verifyNativeCompletionReceiptExact(completed.completion,plan:plan,resourcePermit:permit)
        return plan
    }
    /// Read-only completed native projection. Keeps original FOUR-root evidence; no admission,
    /// checkpoint recapture or parsed HTTP acknowledgment can construct static content.
    func projectNativeCompletedStaticExact(_ request:DeviceNativeProvisioningRequest,
        completed:DeviceNativeProvisioningCompletionAcknowledgment)throws->DeviceManagedStaticContent {
        var result:DeviceManagedStaticContent?
        try nativeCompletionScope {permit in
            _ = try verifyNativeCompletedForHTTP(request,completed:completed,permit:permit)
            guard let selected=request.candidate.configuredEntryID,
                  let entry=request.candidate.entries.first(where:{$0.entryID == selected}) else {
                throw DeviceManagedRenderFailure.emptySelection
            }
            let resolution:DevicePackageTerminalResolution
            if let live=completed.structural {resolution=live.terminal.resolution}
            else if let recovered=completed.recovered {resolution=recovered.packages}
            else {throw DeviceLocalResourceGateFailure.invalidScope}
            guard let receipt=resolution.receipts.first(where:{$0.reference == entry.preparedPackage}) else {
                throw DeviceManagedRenderFailure.invalidContent
            }
            let verified=try packages.verify(receipt,resourcePermit:permit)
            result=try DeviceManagedRenderProjection.make(package:verified.package,
                operationID:completed.operationID,generationID:request.candidate.generationID,
                entryID:entry.entryID,displayName:entry.displayName,validate:{[self] in
                    try verifyNativeCompletedStaticResourcesExact(request,completed:completed)
                })
            _ = try verifyNativeCompletedForHTTP(request,completed:completed,permit:permit)
        }
        guard let result else {throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    private func verifyNativeCompletedStaticResourcesExact(_ request:DeviceNativeProvisioningRequest,
        completed:DeviceNativeProvisioningCompletionAcknowledgment)throws {
        try nativeCompletionScope {permit in
            _ = try verifyNativeCompletedForHTTP(request,completed:completed,permit:permit)
        }
    }
    /// Activated bytes originate only from genuine whole-scope completion and immutable original
    /// authorization. No boolean, parsed outcome or absence can manufacture this outgoing body.
    func retainNativeActivatedReceiptExact(_ request:DeviceNativeProvisioningRequest,
        completed:DeviceNativeProvisioningCompletionAcknowledgment,
        authorization:DeviceNativeRetainedAuthorization)throws->DeviceNativeOutgoingActivatedReceipt {
        let observed=try DeviceNativeDeliveryHTTPCodec.observe(authorization.responseBytes,kind:.activationResponse,
            binding:request.delivery,requestID:authorization.requestID)
        guard let digest=observed.authorizationDigest else{throw DeviceLocalResourceGateFailure.invalidScope}
        var object=try DeviceNativeDeliveryAttachmentCodec.object(authorization.request.requestBytes,limit:4096,
            keys:["schemaVersion","operationId","planId","installationId","accountId","locationId","transitionId","expectedInstalledSetGenerationId","desiredSetGenerationId","planDigest","planByteLength","sequence","resultingSetDigest","activationRequestId"])
        object["authorizationDigest"]=digest;object["outcome"]="activated"
        object["previousGenerationId"]=request.delivery.expectedGenerationID.uuidString.lowercased()
        object["resultingGenerationId"]=request.delivery.desiredGenerationID.uuidString.lowercased()
        object["renderState"]="not-observed"
        let bytes=try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys,.withoutEscapingSlashes])
        guard bytes.count <= 16384 else{throw DeviceNativeDeliveryAttachmentCodec.Failure.capacity}
        _ = try DeviceNativeDeliveryHTTPCodec.observe(bytes,kind:.terminalRequest,binding:request.delivery,
            requestID:authorization.requestID,authorizationDigest:digest,expectedOutcome:"activated")
        var pending:DeviceLocalProvisioningIntentStore.NativeHTTPTransition?
        do {
            try nativeCompletionScope {permit in
                let plan=try verifyNativeCompletedForHTTP(request,completed:completed,permit:permit)
                // Old activation epoch is intentionally consumed by genuine completion; actual
                // original request/response nodes and association are checked by the fixed store.
                let transition=try journal.performNativeHTTPExact(completed.structural?.terminal.journal,
                    plan:plan,phase:.receipt,requestID:authorization.requestID,request:bytes,response:nil,
                    completed:completed.completion,commandPermit:.init(permit))
                pending=transition
                _ = try verifyNativeCompletedForHTTP(request,completed:completed,permit:permit)
                try journal.verifyNativeHTTPTransitionExact(transition,resourcePermit:permit)
            }
            guard let pending else{throw DeviceLocalResourceGateFailure.invalidScope}
            return .init(bytes,completed,authorization,try journal.publishNativeHTTPExact(pending,publicationPermit:.init(pending)))
        } catch {if let pending{try journal.discardNativeHTTPExact(pending)};throw error}
    }
    func retainNativeReceiptAcknowledgmentExact(_ request:DeviceNativeProvisioningRequest,
        outgoing:DeviceNativeOutgoingActivatedReceipt,response:Data)throws->DeviceNativeReportedActivatedReceipt {
        guard response.count <= 16384 else{throw DeviceNativeDeliveryAttachmentCodec.Failure.capacity}
        let observation=try DeviceNativeDeliveryHTTPCodec.observe(response,kind:.terminalResponse,
            binding:request.delivery,requestID:outgoing.authorization.requestID,expectedOutcome:"activated")
        guard let receiptID=observation.receiptID else{throw DeviceLocalResourceGateFailure.invalidScope}
        var pending:DeviceLocalProvisioningIntentStore.NativeHTTPTransition?
        do {
            try nativeCompletionScope {permit in
                let plan=try verifyNativeCompletedForHTTP(request,completed:outgoing.completed,permit:permit)
                try journal.verifyNativeHTTPExact(outgoing.receipt,resourcePermit:permit)
                let transition=try journal.performNativeHTTPExact(outgoing.completed.structural?.terminal.journal,
                    plan:plan,phase:.receipt,requestID:outgoing.authorization.requestID,request:outgoing.bytes,response:response,
                    completed:outgoing.completed.completion,commandPermit:.init(permit))
                pending=transition
                _ = try verifyNativeCompletedForHTTP(request,completed:outgoing.completed,permit:permit)
                try journal.verifyNativeHTTPTransitionExact(transition,resourcePermit:permit)
            }
            guard let pending else{throw DeviceLocalResourceGateFailure.invalidScope}
            return .init(receiptID,outgoing,try journal.publishNativeHTTPExact(pending,publicationPermit:.init(pending)))
        } catch {if let pending{try journal.discardNativeHTTPExact(pending)};throw error}
    }

    func completeNativeProvisioningExact(_ request:DeviceNativeProvisioningRequest,
        original:DeviceNativeStructuralCommitAcknowledgment)throws->DeviceNativeProvisioningCompletionAcknowledgment {
        var pending:DeviceLocalProvisioningIntentStore.NativeCompletionTransition?
        do {
            try nativeCompletionScope {permit in
                try verifyNativeCompletionResources(request,original:original,permit:permit)
                let transition=try journal.performNativeCompletionExact(original.terminal.journal,
                    plan:original.terminal.plan,envelope:original.capture.envelopeBytes,
                    structuralRootID:structural.rootID,commandPermit:.init(permit))
                pending=transition
                try verifyNativeCompletionResources(request,original:original,permit:permit)
                try journal.verifyNativeCompletionTransitionExact(transition,plan:original.terminal.plan,resourcePermit:permit)
            }
            guard let pending else{throw DeviceLocalResourceGateFailure.invalidScope}
            let receipt=try journal.publishNativeCompletionExact(pending,publicationPermit:.init(pending))
            return .init(original,receipt)
        } catch {
            if let pending {try journal.discardNativeCompletionExact(pending)}
            throw error
        }
    }
    func captureNativeCompletedRecoveryExact(operationID:UUID,
        resources:DeviceNativeGrantRecoveryResources)throws->DeviceNativeCompletedResourceRecovery {
        let supplied=try terminalCredentialResources(resources)
        var result:DeviceNativeCompletedResourceRecovery?
        try nativeCompletionScope {permit in
            try structural.verifyNativeGenesisExact(supplied.baseline,resourcePermit:permit)
            let p=try packages.captureNativeBatchOriginal(supplied.packages,candidate:supplied.candidate,resourcePermit:permit)
            let fresh=nativeRecoveryResources(supplied,inputs:p.inputs),expected=nativeExpectations(p.inputs)
            let g=try grants.captureTerminalRecoveryExact(operationID:operationID,resources:fresh,expectedEntries:expected,resourcePermit:permit)
            let j=try journal.captureNativeCompletionRecoveryOriginalExact(g.plan,resourcePermit:permit)
            try packages.verifyNativeTerminalBatchOriginal(p,references:fresh.candidate.entries.map(\.preparedPackage),resourcePermit:permit)
            try grants.verifyTerminalRecoveryExact(g,resources:fresh,expectedEntries:expected,resourcePermit:permit)
            try structural.verifyNativeGenesisExact(fresh.baseline,resourcePermit:permit)
            try journal.verifyNativeCompletionRecoveryOriginalExact(j,plan:g.plan,resourcePermit:permit)
            result = .init(j,g,p,fresh)
        }
        guard let result else{throw DeviceLocalResourceGateFailure.invalidScope};return result
    }
    /// Restart repair explicitly requalifies real private items and exact original resources.
    /// The retained native predecessor/current head never becomes a legacy join receipt.
    func completeNativeProvisioningRecoveredExact(_ original:DeviceNativeCompletedResourceRecovery)throws->DeviceNativeProvisioningCompletionAcknowledgment {
        let resources=original.resources,plan=original.grants.plan
        try checkNativeRoots(resources.roots,inputCount:resources.packages.count)
        let references=resources.candidate.entries.map(\.preparedPackage)
        var journalTransition:DeviceLocalProvisioningIntentStore.NativeCompletionRecoveryTransition?
        var grantPending:DeviceNativeGrantPreparationStore.PendingTerminal?
        var structuralPending:DeviceStructuralStore.NativeCommandCapture?
        var completionPending:DeviceLocalProvisioningIntentStore.NativeCompletionTransition?
        do {
            try nativeCompletionScope {permit in
                try journal.verifyNativeCompletionRecoveryOriginalExact(original.journal,plan:plan,resourcePermit:permit)
                try packages.verifyNativeTerminalBatchOriginal(original.packages,references:references,resourcePermit:permit)
                try grants.verifyTerminalRecoveryExact(original.grants,resources:resources,expectedEntries:nativeExpectations(resources.packages),resourcePermit:permit)
                try structural.verifyNativeGenesisExact(resources.baseline,resourcePermit:permit)
                let transition=try journal.performNativeCompletionRecoveryExact(original.journal,plan:plan,commandPermit:.init(permit))
                journalTransition=transition
                try journal.verifyNativeCompletionRecoveryTransitionExact(transition,plan:plan,resourcePermit:permit)
                try packages.verifyNativeTerminalBatchOriginal(original.packages,references:references,resourcePermit:permit)
                try grants.verifyTerminalRecoveryExact(original.grants,resources:resources,expectedEntries:nativeExpectations(resources.packages),resourcePermit:permit)
                try structural.verifyNativeGenesisExact(resources.baseline,resourcePermit:permit)
            }
            guard let journalTransition else{throw DeviceLocalResourceGateFailure.invalidScope}
            let resolution=try packages.resolveRetainedTerminalExact(references,original:original.packages)
            var finalResources:DeviceNativeGrantRecoveryResources?
            try nativeCompletionScope {permit in
                try journal.verifyNativeCompletionRecoveryTransitionExact(journalTransition,plan:plan,resourcePermit:permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
                let inputs=try nativeInputsFromResolution(resources.packages,resolution:resolution,permit:permit)
                let fresh=nativeRecoveryResources(resources,inputs:inputs),expected=nativeExpectations(inputs)
                finalResources=fresh
                try structural.verifyNativeGenesisExact(resources.baseline,resourcePermit:permit)
                try grants.verifyTerminalRecoveryExact(original.grants,resources:fresh,expectedEntries:expected,resourcePermit:permit)
                let pending=try grants.performTerminalRecoveredExact(original.grants,resources:fresh,expectedEntries:expected,commandPermit:.init(permit))
                grantPending=pending
                try grants.verifyRecoveredTerminalPendingExact(pending,original:original.grants,resources:fresh,expectedEntries:expected,resourcePermit:permit)
                try journal.verifyNativeCompletionRecoveryTransitionExact(journalTransition,plan:plan,resourcePermit:permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
                try structural.verifyNativeGenesisExact(resources.baseline,resourcePermit:permit)
            }
            guard let grantPending,let finalResources else{throw DeviceLocalResourceGateFailure.invalidScope}
            func verifyResources(_ permit:DeviceLocalResourcePermit)throws {
                try packages.verifyResolutionCheckpoint(resolution.checkpoint,resourcePermit:permit)
                for receipt in resolution.receipts {_ = try packages.verify(receipt,resourcePermit:permit)}
                try grants.verifyRecoveredTerminalPendingExact(grantPending,original:original.grants,resources:finalResources,
                    expectedEntries:nativeExpectations(finalResources.packages),resourcePermit:permit)
                try structural.verifyNativeGenesisNodesForDispatch(resources.baseline,resourcePermit:permit)
            }
            try nativeCompletionScope {permit in
                try journal.verifyNativeCompletionRecoveryTransitionExact(journalTransition,plan:plan,resourcePermit:permit)
                try verifyResources(permit)
                let body=try DeviceNativeProvisioningIntentCodec.decode(plan.intentBytes)
                let assertions=try DeviceNativeStructuralCommandCodec.encode(NativeStructuralResources(journalRootID:resources.roots.journalID,
                    packageRootID:resources.roots.packageID,grantRootID:resources.roots.grantID,grantOperationID:original.grants.operationID,
                    grantIdentity:body.grantIdentity),limit:8192)
                let outcome=try DeviceNativeStructuralCommandCodec.encode(NativeStructuralOutcome(schemaVersion:2,operationID:plan.nativeOperationID,
                    generationID:resources.candidate.generationID),limit:32768)
                let capture=try structural.performNativeCommandExact(candidate:plan.candidateBytes,assertions:assertions,intent:plan.intentBytes,
                    outcome:outcome,baseline:resources.baseline,commandPermit:.init(permit))
                structuralPending=capture
                try structural.verifyNativeCommandCapture(capture,resourcePermit:permit)
                try journal.verifyNativeCompletionRecoveryTransitionExact(journalTransition,plan:plan,resourcePermit:permit)
                try verifyResources(permit)
            }
            guard let structuralPending else{throw DeviceLocalResourceGateFailure.invalidScope}
            // A genuine new exact structural capture exists before journal completion effects.
            // Original package/private terminal checkpoints remain fixed across both transitions.
            try nativeCompletionScope {permit in
                try journal.verifyNativeCompletionRecoveryTransitionExact(journalTransition,plan:plan,resourcePermit:permit)
                try verifyResources(permit);try structural.verifyNativeCommandCapture(structuralPending,resourcePermit:permit)
                let transition=try journal.performNativeCompletionRecoveredExact(journalTransition,plan:plan,commandPermit:.init(permit))
                completionPending=transition
                try journal.verifyNativeCompletionTransitionExact(transition,plan:plan,resourcePermit:permit)
                try verifyResources(permit);try structural.verifyNativeCommandCapture(structuralPending,resourcePermit:permit)
            }
            guard let completionPending else{throw DeviceLocalResourceGateFailure.invalidScope}
            let grantReceipt=try grants.publishTerminalExact(grantPending,publicationPermit:.init(grantPending))
            let structuralCapture=try structural.publishNativeCommandExact(structuralPending,permit:.init(structuralPending))
            let completed=try journal.publishNativeCompletionExact(completionPending,publicationPermit:.init(completionPending))
            return .init(.init(plan,structuralCapture,grantReceipt,resolution,original),completed)
        } catch {
            if let completionPending {try journal.discardNativeCompletionExact(completionPending)}
            if let structuralPending {try structural.discardNativeCommandExact(structuralPending)}
            if let grantPending {try grants.discardTerminalPublication(grantPending)}
            throw error
        }
    }

    private func nativeCompletionScope(_ body:(DeviceLocalResourcePermit)throws->Void)throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors=try [journal.resourceGateDescriptor,structural.resourceGateDescriptor,
            packages.resourceGateDescriptor,grants.resourceGateDescriptor].sorted {
                if $0.path.utf8.elementsEqual($1.path.utf8){return $0.rootID.uuidString < $1.rootID.uuidString}
                return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
            }
        for i in descriptors.indices {for j in descriptors.indices where j > i {
            guard descriptors[i].instance != descriptors[j].instance,
                  !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[i].path,descriptors[j].path) else{throw DeviceLocalResourceGateFailure.invalidRoots}
        }}
        let permit=DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit)
        defer{permit.invalidate();DeviceLocalResourceRegistry.finish(permit)}
        func acquire(_ index:Int)throws {
            if index == descriptors.count {try DeviceLocalResourceRegistry.execute(permit);try body(permit);return}
            let instance=descriptors[index].instance
            if instance == ObjectIdentifier(journal){try journal.withNativeHTTPResourceGateScope(permit){try acquire(index+1)}}
            else if instance == ObjectIdentifier(structural){try structural.withNativeStructuralResourceGateScope(permit){try acquire(index+1)}}
            else if instance == ObjectIdentifier(packages){try packages.withResourceGateScope(permit){try acquire(index+1)}}
            else{try grants.withNativeTerminalResourceGateScope(permit){try acquire(index+1)}}
        }
        try acquire(0)
    }

    func terminalReservationSizesForTesting(_ request: DeviceNativeProvisioningRequest,
        progress: DeviceNativeBoundCredentialProgress) throws -> [String: Int] {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        var result: [String: Int]?
        try terminalScope { permit in
            try verifyCredentialResources(progress, permit: permit)
            let inputs = try nativeInputsFromResolution(request.packages, resolution: progress.resolution, permit: permit)
            let fresh = try nativePackageRequest(request, plan: progress.plan, inputs: inputs)
            try grants.verifyCredentialsExact(progress.receipt, request: fresh, resourcePermit: permit)
            result = try grants.terminalReservationSizesForTesting(fresh, resourcePermit: permit)
            try verifyCredentialResources(progress, permit: permit)
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }
        return result
    }
    func closeNativeGrantExact(_ request: DeviceNativeProvisioningRequest,
        progress: DeviceNativeBoundCredentialProgress) throws -> DeviceNativeBoundGrantTerminal {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard progress.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        var pending: DeviceNativeGrantPreparationStore.PendingTerminal?
        do {
            try terminalScope { permit in
                try verifyCredentialResources(progress, permit: permit)
                let inputs = try nativeInputsFromResolution(request.packages, resolution: progress.resolution, permit: permit)
                let fresh = try nativePackageRequest(request, plan: progress.plan, inputs: inputs)
                try grants.verifyCredentialsExact(progress.receipt, request: fresh, resourcePermit: permit)
                try verifyCredentialResources(progress, permit: permit)
                let transition = try grants.performTerminalExact(fresh, original: progress.receipt, commandPermit: .init(permit))
                pending = transition
                try grants.verifyTerminalPendingExact(transition, request: fresh, resourcePermit: permit)
                try verifyCredentialResources(progress, permit: permit)
            }
            guard let pending else { throw DeviceLocalResourceGateFailure.invalidScope }
            let receipt = try grants.publishTerminalExact(pending, publicationPermit: .init(pending))
            return .init(progress.journal, progress.genesis, progress.resolution, progress.plan, receipt)
        } catch {
            if let pending { try grants.discardTerminalPublication(pending) }
            throw error
        }
    }
    private func verifyTerminalResources(_ progress: DeviceNativeBoundGrantTerminal,
        permit: DeviceLocalResourcePermit) throws {
        try structural.verifyNativeGenesisExact(progress.genesis, resourcePermit: permit)
        try journal.verifyNativePrivatePrerequisiteExact(progress.journal, plan: progress.plan, resourcePermit: permit)
        try packages.verifyResolutionCheckpoint(progress.resolution.checkpoint, resourcePermit: permit)
        guard progress.resolution.receipts.count <= 12 else { throw DeviceNativeGrantPreparationError.sizeLimit }
        for receipt in progress.resolution.receipts { _ = try packages.verify(receipt, resourcePermit: permit) }
    }
    func verifyNativeGrantTerminalExact(_ progress: DeviceNativeBoundGrantTerminal,
        request: DeviceNativeProvisioningRequest) throws {
        try checkNativeRoots(request.roots, inputCount: request.packages.count)
        guard progress.operationID == request.grantOperationID else { throw DeviceNativeGrantPreparationError.conflict }
        try terminalScope { permit in
            try verifyTerminalResources(progress, permit: permit)
            let inputs = try nativeInputsFromResolution(request.packages, resolution: progress.resolution, permit: permit)
            let fresh = try nativePackageRequest(request, plan: progress.plan, inputs: inputs)
            try grants.verifyTerminalExact(progress.receipt, request: fresh, resourcePermit: permit)
            try verifyTerminalResources(progress, permit: permit)
        }
    }
    func captureNativeGrantTerminalRecoveryExact(operationID: UUID,
        resources: DeviceNativeGrantRecoveryResources) throws -> DeviceNativeGrantTerminalRecovery {
        let terminal = try terminalCredentialResources(resources)
        var originalPackages: DevicePackagePreparationStore.NativeBatchOriginal?
        var originalGrant: DeviceNativeGrantPreparationStore.TerminalRecovery?
        var originalJournal: DeviceLocalProvisioningIntentStore.NativeJoinOriginal?
        var freshResources: DeviceNativeGrantRecoveryResources?
        try terminalScope { permit in
            try structural.verifyNativeGenesisExact(terminal.baseline, resourcePermit: permit)
            let p = try packages.captureNativeBatchOriginal(terminal.packages, candidate: terminal.candidate, resourcePermit: permit)
            let fresh = nativeRecoveryResources(terminal, inputs: p.inputs), expected = nativeExpectations(p.inputs)
            let g = try grants.captureTerminalRecoveryExact(operationID: operationID, resources: fresh,
                expectedEntries: expected, resourcePermit: permit)
            let j = try journal.captureNativeJoinOriginal(g.plan, attachment: nil, resourcePermit: permit)
            try grants.verifyTerminalRecoveryExact(g, resources: fresh, expectedEntries: expected, resourcePermit: permit)
            try packages.verifyNativeBatchOriginal(p, resourcePermit: permit)
            try structural.verifyNativeGenesisExact(terminal.baseline, resourcePermit: permit)
            originalPackages = p; originalGrant = g; originalJournal = j; freshResources = fresh
        }
        guard let originalPackages, let originalGrant, let originalJournal, let freshResources else {
            throw DeviceLocalResourceGateFailure.invalidScope
        }
        return .init(originalPackages, originalGrant, originalJournal, freshResources)
    }
    func closeNativeGrantRecoveredExact(_ recovery: DeviceNativeGrantTerminalRecovery) throws -> DeviceNativeBoundGrantTerminal {
        let resources = recovery.resources, plan = recovery.grants.plan
        try checkNativeRoots(resources.roots, inputCount: resources.packages.count)
        let references = resources.candidate.entries.map(\.preparedPackage)
        var j: DeviceLocalProvisioningIntentStore.NativeJoinTransition?
        var g: DeviceNativeGrantPreparationStore.PendingTerminal?
        var prerequisite: DeviceLocalProvisioningIntentStore.NativePrivatePrerequisite?
        do {
            // Every original and all terminal/mapping branches precede even journal repair.
            try terminalScope { permit in
                try packages.verifyNativeTerminalBatchOriginal(recovery.packages, references: references, resourcePermit: permit)
                try grants.verifyTerminalRecoveryExact(recovery.grants, resources: resources,
                    expectedEntries: nativeExpectations(resources.packages), resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                let transition = try journal.performNativeJoinExact(plan, original: recovery.journal, commandPermit: .init(permit))
                j = transition
                try journal.verifyNativeJoinTransition(transition, plan: plan, resourcePermit: permit)
                try packages.verifyNativeTerminalBatchOriginal(recovery.packages, references: references, resourcePermit: permit)
                try grants.verifyTerminalRecoveryExact(recovery.grants, resources: resources,
                    expectedEntries: nativeExpectations(resources.packages), resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let j else { throw DeviceLocalResourceGateFailure.invalidScope }
            // Exact original-to-new package repair only. Original grant/genesis and the actual
            // journal transition are retained; no antecedent is refreshed after this unlock.
            let resolution = try packages.resolveRetainedTerminalExact(references, original: recovery.packages)
            var finalResources: DeviceNativeGrantRecoveryResources?
            try terminalScope { permit in
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                let inputs = try nativeInputsFromResolution(resources.packages, resolution: resolution, permit: permit)
                let fresh = nativeRecoveryResources(resources, inputs: inputs), expected = nativeExpectations(inputs)
                finalResources = fresh
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
                try grants.verifyTerminalRecoveryExact(recovery.grants, resources: fresh, expectedEntries: expected, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                let transition = try grants.performTerminalRecoveredExact(recovery.grants, resources: fresh,
                    expectedEntries: expected, commandPermit: .init(permit))
                g = transition
                try grants.verifyRecoveredTerminalPendingExact(transition, original: recovery.grants, resources: fresh,
                    expectedEntries: expected, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let g, let finalResources else { throw DeviceLocalResourceGateFailure.invalidScope }
            let joined = try journal.publishNativeJoinExact(j, publicationPermit: .init(j))
            try terminalScope { permit in
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                let inputs = try nativeInputsFromResolution(finalResources.packages, resolution: resolution, permit: permit)
                let fresh = nativeRecoveryResources(finalResources, inputs: inputs)
                try grants.verifyRecoveredTerminalPendingExact(g, original: recovery.grants, resources: fresh,
                    expectedEntries: nativeExpectations(inputs), resourcePermit: permit)
                prerequisite = try journal.captureNativePrivatePrerequisiteExact(joined, plan: plan, resourcePermit: permit)
                try journal.verifyNativeJoinTransition(j, plan: plan, resourcePermit: permit)
                try packages.verifyResolutionCheckpoint(resolution.checkpoint, resourcePermit: permit)
                try structural.verifyNativeGenesisExact(resources.baseline, resourcePermit: permit)
            }
            guard let prerequisite else { throw DeviceLocalResourceGateFailure.invalidScope }
            let receipt = try grants.publishTerminalExact(g, publicationPermit: .init(g))
            return .init(prerequisite, resources.baseline, resolution, plan, receipt)
        } catch {
            if let g { try grants.discardTerminalPublication(g) }
            if let j { try journal.discardNativeJoinPublication(j) }
            throw error
        }
    }
    private func nativeStructuralScope(_ body: (DeviceLocalResourcePermit) throws -> Void) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors = try [journal.resourceGateDescriptor, structural.resourceGateDescriptor,
            packages.resourceGateDescriptor, grants.resourceGateDescriptor].sorted {
                if $0.path.utf8.elementsEqual($1.path.utf8) { return $0.rootID.uuidString < $1.rootID.uuidString }
                return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
            }
        for i in descriptors.indices { for j in descriptors.indices where j > i {
            guard descriptors[i].instance != descriptors[j].instance,
                  !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[i].path, descriptors[j].path) else {
                throw DeviceLocalResourceGateFailure.invalidRoots
            }
        } }
        let permit = DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit)
        defer { permit.invalidate(); DeviceLocalResourceRegistry.finish(permit) }
        func acquire(_ index: Int) throws {
            if index == descriptors.count { try DeviceLocalResourceRegistry.execute(permit); try body(permit); return }
            let instance = descriptors[index].instance
            if instance == ObjectIdentifier(journal) { try journal.withNativeHTTPResourceGateScope(permit) { try acquire(index + 1) } }
            else if instance == ObjectIdentifier(structural) { try structural.withNativeStructuralResourceGateScope(permit) { try acquire(index + 1) } }
            else if instance == ObjectIdentifier(packages) { try packages.withResourceGateScope(permit) { try acquire(index + 1) } }
            else { try grants.withNativeTerminalResourceGateScope(permit) { try acquire(index + 1) } }
        }
        try acquire(0)
    }
    private func terminalScope(_ body: (DeviceLocalResourcePermit) throws -> Void) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors = try [journal.resourceGateDescriptor, structural.resourceGateDescriptor,
            packages.resourceGateDescriptor, grants.resourceGateDescriptor].sorted {
                if $0.path.utf8.elementsEqual($1.path.utf8) { return $0.rootID.uuidString < $1.rootID.uuidString }
                return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
            }
        for i in descriptors.indices { for j in descriptors.indices where j > i {
            guard descriptors[i].instance != descriptors[j].instance,
                  !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[i].path, descriptors[j].path) else {
                throw DeviceLocalResourceGateFailure.invalidRoots
            }
        } }
        let permit = DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit)
        defer { permit.invalidate(); DeviceLocalResourceRegistry.finish(permit) }
        func acquire(_ index: Int) throws {
            if index == descriptors.count { try DeviceLocalResourceRegistry.execute(permit); try body(permit); return }
            let instance = descriptors[index].instance
            if instance == ObjectIdentifier(journal) { try journal.withNativeResourceGateScope(permit) { try acquire(index + 1) } }
            else if instance == ObjectIdentifier(structural) { try structural.withResourceGateScope(permit) { try acquire(index + 1) } }
            else if instance == ObjectIdentifier(packages) { try packages.withResourceGateScope(permit) { try acquire(index + 1) } }
            else { try grants.withNativeTerminalResourceGateScope(permit) { try acquire(index + 1) } }
        }
        try acquire(0)
    }
    private func scope(_ body: (DeviceLocalResourcePermit) throws -> Void) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let descriptors = try [journal.resourceGateDescriptor, structural.resourceGateDescriptor,
            packages.resourceGateDescriptor, grants.resourceGateDescriptor].sorted {
                if $0.path.utf8.elementsEqual($1.path.utf8) { return $0.rootID.uuidString < $1.rootID.uuidString }
                return $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
            }
        for i in descriptors.indices { for j in descriptors.indices where j > i {
            guard descriptors[i].instance != descriptors[j].instance,
                  !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[i].path, descriptors[j].path) else {
                throw DeviceLocalResourceGateFailure.invalidRoots
            }
        } }
        let permit = DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit)
        defer { permit.invalidate(); DeviceLocalResourceRegistry.finish(permit) }
        func acquire(_ index: Int) throws {
            if index == descriptors.count { try DeviceLocalResourceRegistry.execute(permit); try body(permit); return }
            let instance = descriptors[index].instance
            if instance == ObjectIdentifier(journal) { try journal.withNativeResourceGateScope(permit) { try acquire(index + 1) } }
            else if instance == ObjectIdentifier(structural) { try structural.withResourceGateScope(permit) { try acquire(index + 1) } }
            else if instance == ObjectIdentifier(packages) { try packages.withResourceGateScope(permit) { try acquire(index + 1) } }
            else { try grants.withResourceGateScope(permit) { try acquire(index + 1) } }
        }
        try acquire(0)
    }
}

/// Schema-3 migration observation obtained while BOTH original resource graphs
/// are locked. This is resource qualification, never controller/Cloud admission.
enum DeviceMixedNativeSource {
    case genesis(DeviceStructuralStore.NativeGenesisCheckpoint, DeviceProvisioningRoots)
    case completed(DeviceNativeProvisioningRequest, DeviceNativeProvisioningCompletionAcknowledgment)
    var state: DeviceNativeStructuralState {
        switch self { case .genesis(let checkpoint, _): return checkpoint.state; case .completed(let request, _): return request.candidate }
    }
    var journalRootID: UUID {
        switch self { case .genesis(_, let roots): return roots.journalID; case .completed(let request, _): return request.roots.journalID }
    }
}
final class DeviceMixedResolvedResources: GrantSecretRedacted {
    let snapshot: DeviceMixedStructuralState
    fileprivate let local: DeviceBoundRestoredRuntimeBinding?
    let nativeSource: DeviceMixedNativeSource
    fileprivate init(snapshot: DeviceMixedStructuralState, local: DeviceBoundRestoredRuntimeBinding?, source: DeviceMixedNativeSource) {
        self.snapshot = snapshot; self.local = local; nativeSource = source
    }
}

extension DeviceLocalResourceGate {
    fileprivate func qualifiedResetCredentialsExact(_ permit: DeviceLocalResourcePermit) throws -> [DeviceOwnedInstallationResetResources.Credential] {
        try grants.qualifiedResetCredentialsExact(permit)
    }
    fileprivate func mixedDescriptors(_ binding: DeviceBoundRestoredRuntimeBinding) throws -> [DeviceLocalResourceDescriptor] {
        try [packages.resourceGateDescriptor, grants.resourceGateDescriptor, structural.resourceGateDescriptor, binding.journal.resourceGateDescriptor]
    }
    fileprivate func acquireMixed(_ descriptor: DeviceLocalResourceDescriptor, binding: DeviceBoundRestoredRuntimeBinding,
        permit: DeviceLocalResourcePermit, body: () throws -> Void) throws -> Bool {
        if descriptor.instance == ObjectIdentifier(packages) { try packages.withResourceGateScope(permit, body); return true }
        if descriptor.instance == ObjectIdentifier(grants) { try grants.withResourceGateScope(permit, body); return true }
        if descriptor.instance == ObjectIdentifier(structural) { try structural.withResourceGateScope(permit, body); return true }
        if descriptor.instance == ObjectIdentifier(binding.journal) { try binding.journal.withResourceGateScope(permit, body); return true }
        return false
    }
    fileprivate func mixedLocalPackage(_ binding: DeviceBoundRestoredRuntimeBinding, entryID: UUID,
        permit: DeviceLocalResourcePermit) throws -> QualifiedDevicePackage {
        let scope = DeviceLocalResourceReadScope(permit, packages, grants, structural)
        let fresh = try verifyBoundRestoredBinding(binding, scope: scope, permit: permit)
        guard let value = fresh.first(where: { if case .retained(let id, _, _) = $0 { return id == entryID }; return false }),
              case .retained(_, _, let verified) = value else { throw DeviceManagedRenderFailure.invalidContent }
        return verified.package
    }
    fileprivate func qualifiedMixedLocalEntries(_ binding: DeviceBoundRestoredRuntimeBinding,
        permit: DeviceLocalResourcePermit) throws -> [DeviceMixedStructuralState.Entry] {
        let scope = DeviceLocalResourceReadScope(permit, packages, grants, structural)
        _ = try verifyBoundRestoredBinding(binding, scope: scope, permit: permit)
        let body = try ProvisioningIntentCodec.decode(binding.plan.canonicalBytes)
        let snapshot = try StructuralStoreCodec.envelope(binding.envelopeBytes).snapshot
        guard let owner = snapshot.contentOwner, snapshot.entries.count == binding.packages.count else { throw DeviceStructuralStoreError.conflict }
        let entries = try snapshot.entries.map { entry -> DeviceMixedStructuralState.Entry in
            guard let package = binding.packages.first(where: { $0.entryID == entry.entryID }) else { throw DeviceStructuralStoreError.conflict }
            return .retainedLocal(.init(entry: entry, package: package.receipt.reference,
                grant: .init(identity: body.grantIdentity, preparationOperationID: body.grantOperationID), owner: owner))
        }
        _ = try verifyBoundRestoredBinding(binding, scope: scope, permit: permit)
        return entries
    }
}

extension DeviceNativeGrantPrivateCoordinator {
    func restoreCompletedStaticSourceExact(operationID: UUID, grantOperationID: UUID,
        grantRevisionID: UUID, baseline: DeviceStructuralStore.NativeGenesisCheckpoint) throws ->
        (DeviceNativeProvisioningRequest, DeviceNativeProvisioningCompletionAcknowledgment) {
        var request: DeviceNativeProvisioningRequest?
        try nativeCompletionScope { permit in
            try structural.verifyNativeGenesisExact(baseline, resourcePermit: permit)
            let delivery = try journal.inspectStoredDeliveryBindingExact(nativeOperationID: operationID, resourcePermit: permit)
            let candidate = try structural.inspectStoredNativeCandidateExact(operationID: operationID, resourcePermit: permit)
            let references = candidate.entries.map(\.preparedPackage)
            let actual = try packages.inspectRetainedTerminalExact(references, resourcePermit: permit)
            let inputs = try candidate.entries.map { entry -> DeviceProvisioningPackageInput in
                guard let verified = actual.first(where: { $0.reference == entry.preparedPackage }),
                      verified.package.manifest.connections.isEmpty else { throw NativeDeliveryExecutionError.unsupportedCapabilities }
                return .retained(entryID: entry.entryID, reference: entry.preparedPackage, verified: verified)
            }
            let grantEntries = try candidate.entries.map { entry -> DeviceGrantEntryInput in
                guard let verified = actual.first(where: { $0.reference == entry.preparedPackage }) else { throw NativeDeliveryExecutionError.association }
                return .init(entryID: entry.entryID, revision: verified.package.revision,
                    generic: nil, homeAssistant: nil, publicReads: nil, credentialReferences: [])
            }
            let expectations = try candidate.entries.map { entry -> DeviceGrantEntryExpectation in
                guard let verified = actual.first(where: { $0.reference == entry.preparedPackage }) else { throw NativeDeliveryExecutionError.association }
                return .init(entryID: entry.entryID, package: verified.package)
            }
            let input = DeviceNativeGrantRevisionInput(schemaVersion: 2, identity: .init(rootID: grants.rootID, revisionID: grantRevisionID),
                owner: candidate.owner, entries: grantEntries, credentials: [], retainedRevisions: [])
            let qualified = try DeviceNativeGrantRevisionQualifier.qualify(input, expectedEntries: expectations)
            request = .init(roots: .init(journalID: journal.rootID, structuralID: structural.rootID, packageID: packages.rootID, grantID: grants.rootID),
                delivery: delivery, grantOperationID: grantOperationID, baseline: baseline, candidate: candidate,
                packages: inputs, grantInput: input, qualifiedGrant: qualified)
        }
        guard let request else { throw DeviceLocalResourceGateFailure.invalidScope }
        let resources = DeviceNativeGrantRecoveryResources(roots: request.roots, delivery: request.delivery,
            baseline: request.baseline, candidate: request.candidate, packages: request.packages)
        let recovery = try captureNativeCompletedRecoveryExact(operationID: grantOperationID, resources: resources)
        let completion = try completeNativeProvisioningRecoveredExact(recovery)
        try verifyUnifiedInventorySourceExact(request, completed: completion)
        return (request, completion)
    }
    func verifyUnifiedInventorySourceExact(_ request: DeviceNativeProvisioningRequest,
        completed: DeviceNativeProvisioningCompletionAcknowledgment) throws {
        try nativeCompletionScope { permit in _ = try verifyNativeCompletedForHTTP(request, completed: completed, permit: permit) }
    }
    func verifyUnifiedGenesisSourceExact(_ checkpoint: DeviceStructuralStore.NativeGenesisCheckpoint) throws {
        try nativeCompletionScope { permit in _ = try qualifiedMixedNativeEntries(.genesis(checkpoint,
            .init(journalID: journal.rootID, structuralID: structural.rootID, packageID: packages.rootID, grantID: grants.rootID)), permit: permit) }
    }
    fileprivate func qualifiedMixedNativeEntries(_ source: DeviceMixedNativeSource,
        permit: DeviceLocalResourcePermit) throws -> [DeviceMixedStructuralState.Entry] {
        switch source {
        case .completed(let request, let completion): return try qualifiedMixedCloudEntries(request, completion: completion, permit: permit)
        case .genesis(let checkpoint, let roots):
            guard roots.journalID == journal.rootID, roots.structuralID == structural.rootID,
                roots.packageID == packages.rootID, roots.grantID == grants.rootID,
                checkpoint.state.entries.isEmpty, checkpoint.state.configuredEntryID == nil else { throw DeviceStructuralStoreError.conflict }
            try structural.verifyNativeEmptyGenesisSourceExact(checkpoint, resourcePermit: permit)
            return []
        }
    }
    fileprivate func qualifiedResetCredentialsExact(_ permit: DeviceLocalResourcePermit) throws -> [DeviceOwnedInstallationResetResources.Credential] {
        try grants.qualifiedResetCredentialsExact(permit)
    }
    fileprivate var mixedDescriptors: [DeviceLocalResourceDescriptor] { get throws {
        try [packages.resourceGateDescriptor, grants.resourceGateDescriptor, structural.resourceGateDescriptor, journal.resourceGateDescriptor]
    } }
    fileprivate func acquireMixed(_ descriptor: DeviceLocalResourceDescriptor, permit: DeviceLocalResourcePermit,
        body: () throws -> Void) throws -> Bool {
        if descriptor.instance == ObjectIdentifier(packages) { try packages.withResourceGateScope(permit, body); return true }
        if descriptor.instance == ObjectIdentifier(grants) { try grants.withNativeTerminalResourceGateScope(permit, body); return true }
        if descriptor.instance == ObjectIdentifier(structural) { try structural.withNativeStructuralResourceGateScope(permit, body); return true }
        if descriptor.instance == ObjectIdentifier(journal) { try journal.withNativeHTTPResourceGateScope(permit, body); return true }
        return false
    }
    fileprivate func mixedCloudPackage(_ request: DeviceNativeProvisioningRequest,
        completion: DeviceNativeProvisioningCompletionAcknowledgment, entryID: UUID,
        permit: DeviceLocalResourcePermit) throws -> QualifiedDevicePackage {
        _ = try verifyNativeCompletedForHTTP(request, completed: completion, permit: permit)
        let resolution: DevicePackageTerminalResolution
        if let live = completion.structural { resolution = live.terminal.resolution }
        else if let recovered = completion.recovered { resolution = recovered.packages }
        else { throw DeviceLocalResourceGateFailure.invalidScope }
        guard let entry = request.candidate.entries.first(where: { $0.entryID == entryID }),
              let receipt = resolution.receipts.first(where: { $0.reference == entry.preparedPackage }) else {
            throw DeviceManagedRenderFailure.invalidContent
        }
        return try packages.verify(receipt, resourcePermit: permit).package
    }
    fileprivate func makeIndependentMixedPackageStore(root: URL, rootID: UUID) -> DevicePackagePreparationStore {
        packages.makeIndependentStore(root: root, rootID: rootID)
    }
    fileprivate func qualifiedMixedCloudEntries(_ request: DeviceNativeProvisioningRequest,
        completion: DeviceNativeProvisioningCompletionAcknowledgment, permit: DeviceLocalResourcePermit) throws -> [DeviceMixedStructuralState.Entry] {
        _ = try verifyNativeCompletedForHTTP(request, completed: completion, permit: permit)
        let grant = DeviceMixedStructuralState.Grant(identity: request.grantInput.identity, preparationOperationID: request.grantOperationID)
        return request.candidate.entries.map { .cloud($0, grant) }
    }
}

/// Fixed provenance-preserving migration resolver. All source stores participate
/// in one physical lock order. No locks cross network/UI work; source receipts and
/// generations remain original and are never refreshed to make stale input pass.
final class DeviceMixedIncomingResources {
    let command: DeviceMixedPreparedCloudCommand
    let packages: DevicePackagePreparationStore
    let resolution: DevicePackageTerminalResolution
    let grant: DeviceMixedInventoryStore.StaticGrantReceipt
    fileprivate init(command: DeviceMixedPreparedCloudCommand, packages: DevicePackagePreparationStore,
        resolution: DevicePackageTerminalResolution, grant: DeviceMixedInventoryStore.StaticGrantReceipt) {
        self.command = command; self.packages = packages; self.resolution = resolution; self.grant = grant
    }
}

final class DeviceMixedResourceResolver {
    private let resourceMutex = NSLock()
    private var incomingResources: [DeviceMixedIncomingResources] = []
    private var incomingLocalResources: [DeviceMixedIncomingLocalResources] = []
    private func localIncomingSnapshot() -> [DeviceMixedIncomingLocalResources] {
        resourceMutex.lock(); defer { resourceMutex.unlock() }; return incomingLocalResources
    }
    private func incomingSnapshot() -> [DeviceMixedIncomingResources] {
        resourceMutex.lock(); defer { resourceMutex.unlock() }; return incomingResources
    }
    private let local: DeviceLocalResourceGate?
    private let native: DeviceNativeGrantPrivateCoordinator
    init(local: DeviceLocalResourceGate? = nil, native: DeviceNativeGrantPrivateCoordinator) { self.local = local; self.native = native }
    private func qualifiedLocalEntries(_ binding: DeviceBoundRestoredRuntimeBinding?, permit: DeviceLocalResourcePermit) throws -> [DeviceMixedStructuralState.Entry] {
        var entries: [DeviceMixedStructuralState.Entry] = []
        if let local, let binding { entries = try local.qualifiedMixedLocalEntries(binding, permit: permit) }
        else { guard local == nil, binding == nil else { throw DeviceLocalResourceGateFailure.invalidRoots } }
        for source in localIncomingSnapshot() { entries += try source.gate.qualifiedMixedLocalEntries(source.binding, permit: permit) }
        return entries
    }
    func resolveInitialMigrationExact(local binding: DeviceBoundRestoredRuntimeBinding?,
        native request: DeviceNativeProvisioningRequest, completed: DeviceNativeProvisioningCompletionAcknowledgment,
        generationID: UUID) throws -> DeviceMixedResolvedResources {
        try resolveInitialMigrationExact(local: binding, native: .completed(request, completed), generationID: generationID)
    }
    func resolveInitialMigrationExact(local binding: DeviceBoundRestoredRuntimeBinding?,
        native source: DeviceMixedNativeSource,
        generationID: UUID) throws -> DeviceMixedResolvedResources {
        var result: DeviceMixedResolvedResources?
        try withScope(binding: binding) { permit in
            let retained = try qualifiedLocalEntries(binding, permit: permit)
            let cloud = try native.qualifiedMixedNativeEntries(source, permit: permit)
            let old = try binding.map { try StructuralStoreCodec.envelope($0.envelopeBytes).snapshot }
            guard generationID != old?.generationID, generationID != source.state.generationID else { throw DeviceStructuralStoreError.conflict }
            // Native source is a genuinely completed explicit delivery, later than
            // the imported legacy inventory. Migration itself is not a Local intent.
            let selection = source.state.configuredEntryID ?? old?.configuredEntryID
            let snapshot = try DeviceMixedStructuralState.validating(generationID: generationID,
                installationOwner: source.state.owner, entries: retained + cloud, configuredEntryID: selection)
            _ = try DeviceMixedStructuralStateCodec.encode(snapshot)
            _ = try qualifiedLocalEntries(binding, permit: permit)
            _ = try native.qualifiedMixedNativeEntries(source, permit: permit)
            result = .init(snapshot: snapshot, local: binding, source: source)
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    func verifyCurrentInventoryResourcesExact(_ original: DeviceMixedResolvedResources,
        store: DeviceMixedInventoryStore, current: DeviceMixedInventoryStore.Capture) throws {
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            try store.verifyExact(current, permit: permit)
            guard current.snapshot.installationOwner == original.snapshot.installationOwner,
                  current.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
        }
    }
    func commitInitialMigrationExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        operationID: UUID, admissionEnabled: Bool) throws -> (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt) {
        // Representation migration preserves already qualified accepted content;
        // rollout disables subsequent commands, never decoding/migration itself.
        var result: (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt)?
        try withScope(binding: original.local, inventory: store) { permit in
            let retained = try qualifiedLocalEntries(original.local, permit: permit)
            let cloud = try native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
            guard original.snapshot.entries == retained + cloud else { throw DeviceStructuralStoreError.conflict }
            result = try store.commitExact(operationID: operationID, previous: nil, candidate: original.snapshot,
                admissionEnabled: true, permit: permit)
            _ = try qualifiedLocalEntries(original.local, permit: permit)
            _ = try native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    /// Select/removal commands preserve original resource identities. A new candidate
    /// may only retain the qualified originals, never insert an unverified package.
    func commitAutomaticSelectionExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        permit automatic: DeviceUnifiedAutomaticSelectionPermit, operationID: UUID, generationID: UUID) throws -> DeviceMixedInventoryStore.Capture {
        var result: DeviceMixedInventoryStore.Capture?
        try withScope(binding: original.local, inventory: store) { permit in
            let previous = automatic.baseCapture
            try store.verifyExact(previous, permit: permit)
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            guard previous.snapshot.entries.allSatisfy({ qualified.contains($0) }),
                previous.snapshot.entries.contains(where: { $0.entryID == automatic.targetEntryID }),
                generationID != previous.snapshot.generationID else { throw DeviceStructuralStoreError.conflict }
            let restoring: Bool
            let selected: UUID?
            switch automatic.phase {
            case .activate:
                restoring = false; selected = automatic.targetEntryID
                guard automatic.previousEntryID == previous.snapshot.configuredEntryID, automatic.deadline > Date() else { throw DeviceStructuralStoreError.conflict }
            case .restore:
                restoring = true; selected = automatic.previousEntryID
                guard previous.snapshot.configuredEntryID == automatic.targetEntryID else { throw DeviceStructuralStoreError.conflict }
            }
            let candidate = try DeviceMixedStructuralState.validating(generationID: generationID,
                installationOwner: previous.snapshot.installationOwner, entries: previous.snapshot.entries, configuredEntryID: selected)
            let frame = DeviceMixedInventoryStore.AutomationFrame(operationID: operationID,
                explicitBaseGenerationID: automatic.explicitBaseGenerationID, ownedGenerationID: generationID,
                targetEntryID: automatic.targetEntryID, previousEntryID: automatic.previousEntryID, deadline: automatic.deadline,
                alertID: automatic.alertID, navigation: automatic.navigation, origin: "screenAutomation")
            try store.retainAutomationExact(frame, previous: previous, restoring: restoring, permit: permit)
            result = try store.commitExact(operationID: operationID, previous: previous, candidate: candidate,
                admissionEnabled: true, permit: permit).0
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    func commitSelectionOrRemovalExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        previous: DeviceMixedInventoryStore.Capture, operationID: UUID, generationID: UUID,
        retainedEntryIDs: [UUID], configuredEntryID: UUID?, admissionEnabled: Bool) throws -> (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt) {
        var result: (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt)?
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            try store.verifyExact(previous, permit: permit)
            guard generationID != previous.snapshot.generationID, Set(retainedEntryIDs).count == retainedEntryIDs.count,
                previous.snapshot.entries.allSatisfy({ qualified.contains($0) }),
                retainedEntryIDs.allSatisfy({ id in previous.snapshot.entries.contains(where: { $0.entryID == id }) }) else { throw DeviceStructuralStoreError.conflict }
            let entries = try retainedEntryIDs.map { id -> DeviceMixedStructuralState.Entry in
                guard let entry = previous.snapshot.entries.first(where: { $0.entryID == id }) else { throw DeviceStructuralStoreError.conflict }; return entry
            }
            let candidate = try DeviceMixedStructuralState.validating(generationID: generationID,
                installationOwner: previous.snapshot.installationOwner, entries: entries, configuredEntryID: configuredEntryID)
            result = try store.commitExact(operationID: operationID, previous: previous, candidate: candidate,
                admissionEnabled: admissionEnabled, permit: permit)
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    func commitIncomingLocalExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        previous: DeviceMixedInventoryStore.Capture, source: DeviceMixedIncomingLocalResources,
        operationID: UUID, generationID: UUID, retainedEntryIDs: [UUID], selected: UUID?, peerPinHex: String) throws -> DeviceMixedInventoryStore.Capture {
        var result: DeviceMixedInventoryStore.Capture?
        let prior = localIncomingSnapshot()
        try withScope(binding: original.local, inventory: store, incomingLocal: prior + [source]) { permit in
            let existing = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            let incoming = try source.gate.qualifiedMixedLocalEntries(source.binding, permit: permit)
            guard source.operationID == operationID, !incoming.isEmpty,
                incoming.allSatisfy({ entry in
                    guard case .retainedLocal(let value) = entry else { return false }
                    return value.owner.publicKey.map { String(format: "%02x", $0) }.joined() == peerPinHex
                }), Set(retainedEntryIDs).count == retainedEntryIDs.count,
                previous.snapshot.entries.allSatisfy({ existing.contains($0) }),
                retainedEntryIDs.allSatisfy({ id in previous.snapshot.entries.contains(where: { $0.entryID == id }) }),
                incoming.allSatisfy({ incomingEntry in
                    guard let existing = previous.snapshot.entries.first(where: { $0.entryID == incomingEntry.entryID }) else { return true }
                    guard case .retainedLocal = existing else { return false }
                    return existing.dashboardID == incomingEntry.dashboardID && retainedEntryIDs.contains(existing.entryID)
                }) else { throw DeviceStructuralStoreError.conflict }
            try store.verifyExact(previous, permit: permit)
            let retained = retainedEntryIDs.compactMap { id in
                incoming.first(where: { $0.entryID == id }) ?? previous.snapshot.entries.first(where: { $0.entryID == id })
            }
            let appended = incoming.filter { !retainedEntryIDs.contains($0.entryID) }
            let candidate = try DeviceMixedStructuralState.validating(generationID: generationID,
                installationOwner: previous.snapshot.installationOwner, entries: retained + appended, configuredEntryID: selected)
            try store.retainLocalSourceExact(operationID: operationID, candidate: candidate,
                descriptors: source.gate.mixedDescriptors(source.binding), permit: permit)
            result = try store.commitExact(operationID: operationID, previous: previous, candidate: candidate, admissionEnabled: true, permit: permit).0
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }
        resourceMutex.lock()
        if !incomingLocalResources.contains(where: { $0.operationID == source.operationID }) { incomingLocalResources.append(source) }
        resourceMutex.unlock(); return result
    }
    private func qualifiedIncomingEntries(_ resources: [DeviceMixedIncomingResources], store: DeviceMixedInventoryStore,
        permit: DeviceLocalResourcePermit) throws -> [DeviceMixedStructuralState.Entry] {
        var entries: [DeviceMixedStructuralState.Entry] = []
        for original in resources {
            try store.verifyIncomingStaticGrantExact(original.grant, permit: permit)
            try original.packages.verifyResolutionCheckpoint(original.resolution.checkpoint, resourcePermit: permit)
            for receipt in original.resolution.receipts {
                let verified = try original.packages.verify(receipt, resourcePermit: permit)
                guard let entry = original.command.candidate.entries.first(where: { value in
                    if case .cloud(let cloud, let grant) = value { return cloud.preparedPackage == receipt.reference
                        && grant.identity == original.command.grantInput.identity
                        && verified.package.revision.digest == cloud.package.manifestDigest.text }; return false
                }) else { throw DeviceManagedRenderFailure.invalidContent }
                entries.append(entry)
            }
        }
        return entries
    }
    /// Resource preparation only. Exact operation intent/public static grant is
    /// durable before incoming package effects; no installed generation changes.
    func restoreIncomingLocalResourcesExact(store: DeviceMixedInventoryStore, sources: [DeviceMixedIncomingLocalResources]) throws {
        let frames = try store.retainedLocalSourcesExact()
        guard Set(sources.map(\.operationID)).count == sources.count, sources.count == frames.count else { throw DeviceStructuralStoreError.conflict }
        for frame in frames {
            guard let source = sources.first(where: { $0.operationID == frame.operationID }),
                try source.gate.mixedDescriptors(source.binding).map({ DeviceMixedInventoryStore.LocalSourceRoot(rootID: $0.rootID, path: $0.path) }).sorted(by: { $0.path < $1.path }) == frame.roots else { throw DeviceStructuralStoreError.conflict }
        }
        resourceMutex.lock(); incomingLocalResources = sources; resourceMutex.unlock()
    }
    func restoreIncomingCloudResourcesExact(store: DeviceMixedInventoryStore) throws {
        let retained = try store.retainedIncomingFramesExact()
        var restored: [DeviceMixedIncomingResources] = []
        for record in retained {
            let frame = record.frame
            let expectedPath = try store.incomingPackageRootExact(operationID: frame.operationID).path
            guard frame.incomingPackagePath == expectedPath, frame.grantIdentity.rootID == store.rootID else { throw DeviceStructuralStoreError.conflict }
            let packages = makeIncomingPackageStore(root: URL(fileURLWithPath: frame.incomingPackagePath), rootID: frame.incomingPackageRootID)
            let candidate = try DeviceMixedStructuralStateCodec.decode(frame.candidate)
            let references = candidate.entries.compactMap { entry -> DevicePreparedPackageReference? in
                guard case .cloud(let cloud, let grant) = entry, grant.identity == frame.grantIdentity,
                    grant.preparationOperationID == frame.grantOperationID else { return nil }; return cloud.preparedPackage
            }
            let resolution = try packages.resolveRetainedTerminalExact(references)
            let verified = try resolution.receipts.map { try packages.verify($0) }
            let a = frame.deliveryAssociation
            let object: [String: Any] = ["schemaVersion": 1, "operationId": a.operationID.uuidString.lowercased(),
                "planId": a.planID.uuidString.lowercased(), "installationId": a.installationID.uuidString.lowercased(),
                "accountId": a.accountID.uuidString.lowercased(), "locationId": a.locationID.map { $0.uuidString.lowercased() } as Any? ?? NSNull(),
                "transitionId": a.transitionID.uuidString.lowercased(), "planDigest": a.planDigest, "planByteLength": a.planByteLength]
            let header = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let delivery = try DeviceNativeDeliveryCommandBinding.bindMixed(command: frame.deliveryCommand, associationHeader: header,
                rawPlan: frame.deliveryPlan, nativeOperationID: frame.operationID, journalRootID: frame.journalRootID, capture: record.original)
            let command = try DeviceMixedPreparedCloudCommand.restore(capture: record.original, delivery: delivery,
                candidate: candidate, grantIdentity: frame.grantIdentity, grantOperationID: frame.grantOperationID, packages: verified)
            guard command.qualifiedGrant.publicMetadataBytes == frame.publicMetadata else { throw DeviceStructuralStoreError.conflict }
            restored.append(.init(command: command, packages: packages, resolution: resolution, grant: record.grant))
        }
        resourceMutex.lock(); defer { resourceMutex.unlock() }
        guard incomingResources.isEmpty else { throw DeviceStructuralStoreError.conflict }
        incomingResources = restored
    }
    func retainMountedEmptyExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture) throws {
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            try store.verifyExact(current, permit: permit)
            guard current.snapshot.entries.allSatisfy({ qualified.contains($0) }), current.snapshot.configuredEntryID == nil else { throw DeviceStructuralStoreError.conflict }
            try store.retainMountedEmptyExact(current, permit: permit)
        }
    }
    func retainMountedContentExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture, content: DeviceManagedStaticContent, failureCode: String? = nil) throws {
        try content.verifyResources()
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            try store.verifyExact(current, permit: permit)
            guard current.snapshot.entries.allSatisfy({ qualified.contains($0) }), content.generationID == current.snapshot.generationID,
                current.snapshot.configuredEntryID == content.entryID, let entry = current.snapshot.entries.first(where: { $0.entryID == content.entryID }) else { throw DeviceStructuralStoreError.conflict }
            let digest: String
            switch entry { case .retainedLocal(let local): digest = local.entry.revision.digest
            case .cloud(let cloud, _): digest = cloud.package.manifestDigest.text }
            if let failureCode { try store.retainMountFailureExact(current, entryID: content.entryID, code: failureCode, permit: permit) }
            else { try store.retainMountedExact(current, entryID: content.entryID, digest: digest, permit: permit) }
        }
    }
    func retainCloudRejectionExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        binding: DeviceNativeDeliveryCommandBinding, bytes: Data, acknowledgment: Bool = false) throws -> Bool {
        var retained = false
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            guard let current = try store.captureCurrentExact(permit: permit), current.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            retained = try store.retainCloudRejectionExact(binding: binding, bytes: bytes, acknowledgment: acknowledgment, permit: permit)
        }
        return retained
    }
    func retainCloudAcceptedExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        previous: DeviceMixedInventoryStore.Capture, binding: DeviceNativeDeliveryCommandBinding) throws {
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            guard previous.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            try store.retainCloudAcceptedExact(binding: binding, previous: previous, permit: permit)
        }
    }
    func verifyPreparedIncomingCloudExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        incoming: DeviceMixedIncomingResources) throws {
        try withScope(binding: original.local, inventory: store, incoming: incomingSnapshot() + [incoming]) { permit in
            _ = try qualifiedLocalEntries(original.local, permit: permit)
            _ = try native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
            _ = try qualifiedIncomingEntries([incoming], store: store, permit: permit)
        }
    }
    func restoredIncomingCloudExact(operationID: UUID) throws -> DeviceMixedIncomingResources {
        guard let incoming = incomingSnapshot().first(where: { $0.command.delivery.nativeOperationID == operationID }) else { throw DeviceStructuralStoreError.conflict }
        return incoming
    }
    func makeIncomingPackageStore(root: URL, rootID: UUID) -> DevicePackagePreparationStore {
        native.makeIndependentMixedPackageStore(root: root, rootID: rootID)
    }
    func prepareIncomingCloudResourcesExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        command: DeviceMixedPreparedCloudCommand, packages: DevicePackagePreparationStore) throws -> DeviceMixedIncomingResources {
        var result: DeviceMixedIncomingResources?
        let prior = incomingSnapshot()
        try withScope(binding: original.local, inventory: store, incoming: prior, preparing: packages) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(prior, store: store, permit: permit)
            try store.verifyExact(command.capture, permit: permit)
            guard command.capture.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            let grant = try store.retainIncomingStaticGrantExact(command, incomingPackageRoot: packages.resourceGateDescriptor, permit: permit)
            let resolution = try packages.performMixedIncomingPackagesExact(command, commandPermit: .init(permit))
            try store.verifyIncomingStaticGrantExact(grant, permit: permit)
            try store.verifyExact(command.capture, permit: permit)
            result = .init(command: command, packages: packages, resolution: resolution, grant: grant)
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    func retainIncomingHTTPExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        incoming: DeviceMixedIncomingResources, kind: DeviceMixedInventoryStore.HTTPRecordKind, bytes: Data) throws {
        let prior = incomingSnapshot()
        try withScope(binding: original.local, inventory: store, incoming: prior + [incoming]) { permit in
            _ = try qualifiedLocalEntries(original.local, permit: permit)
            _ = try native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
            _ = try qualifiedIncomingEntries(prior + [incoming], store: store, permit: permit)
            if kind == .outcome {
                try store.verifyCompletedCandidateExact(operationID: incoming.command.delivery.nativeOperationID,
                    candidate: incoming.command.candidate, permit: permit)
            } else if kind != .acknowledgment { try store.verifyExact(incoming.command.capture, permit: permit) }
            try store.retainIncomingHTTPExact(incoming, kind: kind, bytes: bytes, permit: permit)
        }
    }
    /// Fixed owner calls only after exact Cloud activation/current-intent admission.
    func commitIncomingCloudResourcesExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        incoming: DeviceMixedIncomingResources, admissionEnabled: Bool) throws -> (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt) {
        var result: (DeviceMixedInventoryStore.Capture, DeviceMixedInventoryStore.Receipt)?
        let prior = incomingSnapshot()
        try withScope(binding: original.local, inventory: store, incoming: prior + [incoming]) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(prior + [incoming], store: store, permit: permit)
            guard incoming.command.candidate.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            result = try store.commitExact(operationID: incoming.command.delivery.nativeOperationID,
                previous: incoming.command.capture, candidate: incoming.command.candidate,
                admissionEnabled: admissionEnabled, permit: permit)
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }
        resourceMutex.lock()
        if !incomingResources.contains(where: { $0.command.delivery.nativeOperationID == incoming.command.delivery.nativeOperationID }) { incomingResources.append(incoming) }
        resourceMutex.unlock()
        return result
    }
    private func cloudStateBytes(_ snapshot: DeviceMixedStructuralState) throws -> Data {
        let entries: [[String: Any]] = snapshot.entries.map { entry in
            let provenance: [String: Any]
            switch entry {
            case .retainedLocal(let localEntry):
                provenance = ["kind": "retainedLocal", "retainedEntryId": entry.entryID.uuidString.lowercased(),
                "manifestDigest": localEntry.entry.revision.digest]
            case .cloud(let cloudEntry, _):
                let p = cloudEntry.package
                provenance = ["kind": "cloud", "package": ["packageProfile": DeviceDeliveryPackageCandidate.profile,
                "publicationId": p.publicationID.uuidString.lowercased(), "projectId": p.projectID.uuidString.lowercased(),
                "packageId": p.packageID.uuidString.lowercased(), "dashboardId": p.dashboardID.uuidString.lowercased(),
                "revision": p.revision.uuidString.lowercased(), "manifestDigest": p.manifestDigest.text,
                "manifestSha256": p.manifestSHA256.text, "archiveSha256": p.archiveSHA256.text,
                "compressedBytes": p.compressedBytes, "expandedBytes": p.expandedBytes, "archiveEntries": p.archiveEntries]]
            }
            return ["entryId": entry.entryID.uuidString.lowercased(), "provenance": provenance]
        }
        let owner = snapshot.installationOwner
        let state: [String: Any] = ["schemaVersion": 1, "installationId": owner.installationID.uuidString.lowercased(),
            "transitionId": owner.transitionID.uuidString.lowercased(), "generationId": snapshot.generationID.uuidString.lowercased(),
            "entries": entries, "configuredEntryId": snapshot.configuredEntryID.map { $0.uuidString.lowercased() } as Any? ?? NSNull()]
        return try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
    }
    func verifyCloudObservationResourcesExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        observation: DeviceMixedInventoryStore.CloudObservation) throws {
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            let historical = try store.verifyPendingCloudObservationHistoryExact(observation, permit: permit)
            guard historical.entries.allSatisfy({ qualified.contains($0) }),
                  let object = try JSONSerialization.jsonObject(with: observation.exactBody) as? [String: Any],
                  let state = object["state"], try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) == cloudStateBytes(historical) else { throw DeviceStructuralStoreError.conflict }
        }
    }
    func retainCloudObservationExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture, authenticatedCloudGenerationID: UUID) throws -> DeviceMixedInventoryStore.CloudObservation {
        var observation: DeviceMixedInventoryStore.CloudObservation?
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            try store.verifyExact(current, permit: permit)
            guard current.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            try store.initializeCloudObservationCheckpointExact(authenticatedCloudGenerationID, permit: permit)
            observation = try store.enqueueCloudObservationExact(current,
                stateBytes: cloudStateBytes(current.snapshot), permit: permit)
        }
        guard let observation else { throw DeviceLocalResourceGateFailure.invalidScope }; return observation
    }
    func verifyCurrentOrMountedResourcesExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        presentation: DeviceMixedInventoryStore.Capture) throws {
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            guard let current = try store.captureCurrentExact(permit: permit),
                current.snapshot.entries.allSatisfy({ qualified.contains($0) }),
                let id = presentation.snapshot.configuredEntryID,
                let entry = presentation.snapshot.entries.first(where: { $0.entryID == id }), qualified.contains(entry) else { throw DeviceStructuralStoreError.conflict }
            if current.bytes != presentation.bytes {
                guard let mounted = try store.mountedReferenceExact(permit: permit),
                    mounted.generationID == presentation.snapshot.generationID, mounted.entryID == id else { throw DeviceStructuralStoreError.conflict }
                let digest: String
                switch entry { case .retainedLocal(let local): digest = local.entry.revision.digest
                case .cloud(let cloud, _): digest = cloud.package.manifestDigest.text }
                guard mounted.manifestDigest == digest else { throw DeviceStructuralStoreError.conflict }
            }
        }
    }
    func selectedLocalRuntimeSourceExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture) throws -> (gate: DeviceLocalResourceGate, binding: DeviceBoundRestoredRuntimeBinding,
            entryID: UUID, package: QualifiedDevicePackage) {
        guard let id = current.snapshot.configuredEntryID else { throw DeviceManagedRenderFailure.emptySelection }
        return try installedLocalRuntimeSourceExact(original, store: store, current: current, entryID: id)
    }
    func installedLocalRuntimeSourceExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture, entryID: UUID, historicalMounted: Bool = false) throws -> (gate: DeviceLocalResourceGate, binding: DeviceBoundRestoredRuntimeBinding,
            entryID: UUID, package: QualifiedDevicePackage) {
        var result: (DeviceLocalResourceGate, DeviceBoundRestoredRuntimeBinding, UUID, QualifiedDevicePackage)?
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            if historicalMounted {
                guard let mounted = try store.mountedReferenceExact(permit: permit),
                    mounted.generationID == current.snapshot.generationID,
                    mounted.entryID == current.snapshot.configuredEntryID,
                    let live = try store.captureCurrentExact(permit: permit), live.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            } else { try store.verifyExact(current, permit: permit) }
            guard current.snapshot.entries.allSatisfy({ qualified.contains($0) }), let entry = current.snapshot.entries.first(where: { $0.entryID == entryID }), case .retainedLocal = entry else { throw DeviceManagedRenderFailure.invalidContent }
            if let local, let binding = original.local, original.snapshot.entries.contains(entry) {
                result = (local, binding, entryID, try local.mixedLocalPackage(binding, entryID: entryID, permit: permit))
            } else {
                guard let source = try localIncomingSnapshot().first(where: { try $0.gate.qualifiedMixedLocalEntries($0.binding, permit: permit).contains(entry) }) else { throw DeviceManagedRenderFailure.invalidContent }
                result = (source.gate, source.binding, entryID, try source.gate.mixedLocalPackage(source.binding, entryID: entryID, permit: permit))
            }
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    func selectedStaticContentExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture, operationID: UUID, historicalMounted: Bool = false) throws -> DeviceManagedStaticContent {
        var selectedPackage: QualifiedDevicePackage?, selectedName: String?, selectedID: UUID?
        try withScope(binding: original.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original.local, permit: permit)
                + native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
                + qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
            if historicalMounted {
                guard let mounted = try store.mountedReferenceExact(permit: permit),
                    mounted.generationID == current.snapshot.generationID,
                    mounted.entryID == current.snapshot.configuredEntryID,
                    let live = try store.captureCurrentExact(permit: permit), live.snapshot.entries.allSatisfy({ qualified.contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            } else { try store.verifyExact(current, permit: permit) }
            guard current.snapshot.entries.allSatisfy({ qualified.contains($0) }),
                  let id = current.snapshot.configuredEntryID,
                  let entry = current.snapshot.entries.first(where: { $0.entryID == id }) else { throw DeviceManagedRenderFailure.emptySelection }
            selectedID = id
            switch entry {
            case .retainedLocal(let localEntry):
                selectedName = localEntry.entry.displayName
                if let local, let binding = original.local,
                    original.snapshot.entries.contains(entry) {
                    selectedPackage = try local.mixedLocalPackage(binding, entryID: id, permit: permit)
                } else {
                    guard let source = try localIncomingSnapshot().first(where: { try $0.gate.qualifiedMixedLocalEntries($0.binding, permit: permit).contains(entry) }) else { throw DeviceManagedRenderFailure.invalidContent }
                    selectedPackage = try source.gate.mixedLocalPackage(source.binding, entryID: id, permit: permit)
                }
            case .cloud(let cloudEntry, _):
                selectedName = cloudEntry.displayName
                if case .completed(let request, let completion) = original.nativeSource, request.candidate.entries.contains(where: { $0.entryID == id && $0.preparedPackage == cloudEntry.preparedPackage }) {
                    selectedPackage = try native.mixedCloudPackage(request, completion: completion, entryID: id, permit: permit)
                } else {
                    guard let resource = incomingSnapshot().first(where: { $0.resolution.receipts.contains(where: { $0.reference == cloudEntry.preparedPackage }) }),
                          let receipt = resource.resolution.receipts.first(where: { $0.reference == cloudEntry.preparedPackage }) else { throw DeviceManagedRenderFailure.invalidContent }
                    selectedPackage = try resource.packages.verify(receipt, resourcePermit: permit).package
                }
            }
        }
        guard let package = selectedPackage, let name = selectedName, let id = selectedID else { throw DeviceManagedRenderFailure.invalidContent }
        let content = try DeviceManagedRenderProjection.make(package: package, operationID: operationID,
            generationID: current.snapshot.generationID, entryID: id, displayName: name, validate: { [self] in
                try verifyCurrentOrMountedResourcesExact(original, store: store, presentation: current)
            })
        try content.verifyResources(); return content
    }
    func verifyExact(_ original: DeviceMixedResolvedResources) throws {
        try withScope(binding: original.local) { permit in
            let retained = try qualifiedLocalEntries(original.local, permit: permit)
            let cloud = try native.qualifiedMixedNativeEntries(original.nativeSource, permit: permit)
            guard original.snapshot.entries == retained + cloud else { throw DeviceStructuralStoreError.conflict }
        }
    }
    func qualifiedResetResourcesExact(_ original: DeviceMixedResolvedResources, store: DeviceMixedInventoryStore,
        current: DeviceMixedInventoryStore.Capture) throws -> DeviceOwnedInstallationResetResources {
        var result: DeviceOwnedInstallationResetResources?
        try withResetResourcesScope(original: original, source: original.nativeSource, store: store, current: current) { snapshot in
            result = try .init(installationID: snapshot.installationID, roots: snapshot.roots, credentials: snapshot.credentials,
                resourceOperation: { [self] operation in
                    try withResetResourcesScope(original: original, source: original.nativeSource, store: store, current: current) { fresh in
                        guard fresh.installationID == snapshot.installationID, fresh.roots == snapshot.roots,
                            fresh.credentials == snapshot.credentials else { throw DeviceLocalResourceGateFailure.invalidRoots }
                        try operation()
                    }
                })
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    func qualifiedNativeResetResourcesExact(_ source: DeviceMixedNativeSource) throws -> DeviceOwnedInstallationResetResources {
        var result: DeviceOwnedInstallationResetResources?
        try withResetResourcesScope(original: nil, source: source, store: nil, current: nil) { snapshot in
            result = try .init(installationID: snapshot.installationID, roots: snapshot.roots, credentials: snapshot.credentials,
                resourceOperation: { [self] operation in
                    try withResetResourcesScope(original: nil, source: source, store: nil, current: nil) { fresh in
                        guard fresh.installationID == snapshot.installationID, fresh.roots == snapshot.roots,
                            fresh.credentials == snapshot.credentials else { throw DeviceLocalResourceGateFailure.invalidRoots }
                        try operation()
                    }
                })
        }
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
    /// Resource-only retained proof: outer Authority owns admission/reset serialization.
    /// Exact current generation and credential membership are rechecked under all store locks.
    private func withResetResourcesScope(original: DeviceMixedResolvedResources?, source: DeviceMixedNativeSource,
        store: DeviceMixedInventoryStore?, current: DeviceMixedInventoryStore.Capture?,
        body: (DeviceOwnedInstallationResetResources) throws -> Void) throws {
        try withScope(binding: original?.local, inventory: store) { permit in
            let qualified = try qualifiedLocalEntries(original?.local, permit: permit)
                + native.qualifiedMixedNativeEntries(source, permit: permit)
            if let store, let current {
                let incoming = try qualifiedIncomingEntries(incomingSnapshot(), store: store, permit: permit)
                try store.verifyExact(current, permit: permit)
                guard current.snapshot.entries.allSatisfy({ (qualified + incoming).contains($0) }) else { throw DeviceStructuralStoreError.conflict }
            } else { guard store == nil, current == nil, original == nil else { throw DeviceLocalResourceGateFailure.invalidScope } }
            var credentials = try native.qualifiedResetCredentialsExact(permit)
            if let local { credentials += try local.qualifiedResetCredentialsExact(permit) }
            for retained in localIncomingSnapshot() { credentials += try retained.gate.qualifiedResetCredentialsExact(permit) }
            let snapshot = try resetEvidence(permit, installationID: source.state.owner.installationID, credentials: credentials)
            try body(snapshot)
            // A caller cannot hide a changed inventory behind successful pending persistence.
            if let store, let current { try store.verifyExact(current, permit: permit) }
        }
    }
    private func resetEvidence(_ permit: DeviceLocalResourcePermit, installationID: UUID,
        credentials: [DeviceOwnedInstallationResetResources.Credential]) throws -> DeviceOwnedInstallationResetResources {
        try permit.requireReadable()
        let roots = try permit.participants.map { descriptor -> DeviceOwnedInstallationResetResources.Root in
            let fd = open(descriptor.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw DeviceLocalResourceGateFailure.invalidRoots }; defer { close(fd) }
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, lstat(descriptor.path, &named) == 0,
                named.st_mode & S_IFMT == S_IFDIR, held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
                throw DeviceLocalResourceGateFailure.invalidRoots
            }
            return .init(rootID: descriptor.rootID, path: descriptor.path,
                device: UInt64(truncatingIfNeeded: held.st_dev), inode: UInt64(truncatingIfNeeded: held.st_ino))
        }
        return try .init(installationID: installationID, roots: roots, credentials: credentials)
    }
    private func withScope(binding: DeviceBoundRestoredRuntimeBinding?, inventory: DeviceMixedInventoryStore? = nil, incoming: [DeviceMixedIncomingResources]? = nil, preparing: DevicePackagePreparationStore? = nil, incomingLocal: [DeviceMixedIncomingLocalResources]? = nil, body: (DeviceLocalResourcePermit) throws -> Void) throws {
        try DeviceLocalResourceRegistry.requireIdle()
        let retainedIncoming = incoming ?? incomingSnapshot()
        let retainedLocal = incomingLocal ?? localIncomingSnapshot()
        let extraPackages = retainedIncoming.map(\.packages) + (preparing.map { [$0] } ?? [])
        let localDescriptors: [DeviceLocalResourceDescriptor]
        if let local, let binding { localDescriptors = try local.mixedDescriptors(binding) }
        else { guard local == nil, binding == nil else { throw DeviceLocalResourceGateFailure.invalidRoots }; localDescriptors = [] }
        let supplied = try localDescriptors + retainedLocal.flatMap { try $0.gate.mixedDescriptors($0.binding) } + native.mixedDescriptors
            + (inventory.map { try $0.resourceGateDescriptor }.map { [$0] } ?? [])
            + extraPackages.map { try $0.resourceGateDescriptor }
        var descriptors: [DeviceLocalResourceDescriptor] = []
        for descriptor in supplied {
            if let same = descriptors.first(where: { $0.instance == descriptor.instance }) {
                guard same.path == descriptor.path, same.rootID == descriptor.rootID else { throw DeviceLocalResourceGateFailure.invalidRoots }
            } else { descriptors.append(descriptor) }
        }
        descriptors.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        for i in descriptors.indices { for j in descriptors.indices where j > i {
            guard descriptors[i].rootID != descriptors[j].rootID,
                  !DeviceLocalResourceDescriptor.pathsOverlap(descriptors[i].path, descriptors[j].path) else { throw DeviceLocalResourceGateFailure.invalidRoots }
        } }
        let permit = DeviceLocalResourcePermit(descriptors)
        try DeviceLocalResourceRegistry.begin(permit); defer { permit.invalidate(); DeviceLocalResourceRegistry.finish(permit) }
        func acquire(_ index: Int) throws {
            if index == descriptors.count { try DeviceLocalResourceRegistry.execute(permit); try body(permit); return }
            let next = { try acquire(index + 1) }
            if let local, let binding, try local.acquireMixed(descriptors[index], binding: binding, permit: permit, body: next) { return }
            for source in retainedLocal {
                if try source.gate.acquireMixed(descriptors[index], binding: source.binding, permit: permit, body: next) { return }
            }
            if let packageStore = extraPackages.first(where: { descriptors[index].instance == ObjectIdentifier($0) }) {
                try packageStore.withResourceGateScope(permit, next); return
            }
            if let inventory, descriptors[index].instance == ObjectIdentifier(inventory) {
                try inventory.withResourceGateScope(permit, next); return
            }
            guard try native.acquireMixed(descriptors[index], permit: permit, body: next) else { throw DeviceLocalResourceGateFailure.invalidRoots }
        }
        try acquire(0)
    }
}

#if DEBUG
/// Test-only single-root harness; production commits use the complete resolver.
enum DeviceMixedInventoryQualificationHarness {
    static func scope<T>(_ store: DeviceMixedInventoryStore, body: (DeviceLocalResourcePermit) throws -> T) throws -> T {
        let permit = DeviceLocalResourcePermit([try store.resourceGateDescriptor])
        try DeviceLocalResourceRegistry.begin(permit)
        defer { permit.invalidate(); DeviceLocalResourceRegistry.finish(permit) }
        var output: T?
        try store.withResourceGateScope(permit) {
            try DeviceLocalResourceRegistry.execute(permit); output = try body(permit)
        }
        guard let output else { throw DeviceLocalResourceGateFailure.invalidScope }; return output
    }
}
#endif
