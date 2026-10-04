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
/// Short registry critical sections only. Never holds its mutex during waits, I/O or callbacks.
/// All ordinary store entries are marked BEFORE their mutex acquisition, rejecting nested cross-store
/// or gate entry. Thread markers are removed on exit; they are not persistent state or authority.
enum DeviceLocalResourceRegistry {
    private enum State { case ordinary; case gate(DeviceLocalResourcePermit, acquired: Int, phase: Phase, reading: Bool) }
    private enum Phase { case acquiring, executing, closing }
    private static let mutex = NSLock()
    private static var states: [ObjectIdentifier:State] = [:]
    private static var thread: ObjectIdentifier { ObjectIdentifier(Thread.current) }
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
    func diagnoseStructural(operationID: UUID) throws -> DeviceStructuralStore.Recovery {
        try permit.requireReadable(); return try structural.recover(operationID:operationID,resourcePermit:permit)
    }
}
/// Unmounted lock-set exclusion ONLY. No resource checkpoints, recovery acknowledgment, admission,
/// atomic production all-writer authority, creation, sync, migration or callbacks moved outside locks.
/// Body is internal synchronous orchestration, never UI/notification/async work. Existing backend/fault
/// calls execute under locks. Same-thread reentry fails; callbacks synchronously joining another thread
/// doing resource work are unsupported (they can deadlock through application-level waiting).
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
    private func withScope<T>(_ body: (DeviceLocalResourceReadScope,DeviceLocalResourcePermit) throws -> T) throws -> T {
        let descriptors = try [packages.resourceGateDescriptor,grants.resourceGateDescriptor,structural.resourceGateDescriptor]
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
            else { try structural.withResourceGateScope(permit) { try acquire(index+1) } }
        }
        try acquire(0)
        guard let result else { throw DeviceLocalResourceGateFailure.invalidScope }; return result
    }
}
