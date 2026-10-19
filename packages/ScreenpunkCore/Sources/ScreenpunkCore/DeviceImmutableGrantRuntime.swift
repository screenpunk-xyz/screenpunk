import Foundation

/// Nonsecret reservation scope. This unmounted adapter does not implement native owner admission.
struct DeviceImmutableGenericScope:Sendable {
    let structuralRootID:UUID
    let operationID:UUID
    let generationID:UUID
    let entryID:UUID
    let owner:PairingIdentity
    let grants:DeviceGrantRevisionIdentity
}
protocol DeviceImmutableGenericReservation:Sendable {
    func check()throws
    func finish()
}
/// A future native implementation acquires owner authority, server lock, then invokes validation.
/// The synchronous nonescaping validator must succeed exactly once. No default-allow implementation.
/// Cancellation/check linearize admission, not packets: previously admitted work may reach the network
/// before cancellation is observed. This is not an end-to-end network admission guarantee.
/// Caller task cancellation is independent of generation revocation: known cancellation prevents
/// dispatch; late/cached results are refused even when a delegate ignores cancellation.
protocol DeviceImmutableGenericAdmissionDriver:Sendable {
    func reserve(scope:DeviceImmutableGenericScope,validateResources:()throws->Void,
                 onCancel:@escaping @Sendable ()->Void)throws->any DeviceImmutableGenericReservation
}
protocol DeviceImmutableGenericOperations:Sendable {
    func request(alias:String,operation:String,parameters:[String:String])async throws->ConnectionHTTPResult
    func requestRead(alias:String,operation:String,parameters:[String:String])async throws->ConnectionHTTPResult
    func subscribe(alias:String,operation:String,parameters:[String:String])async throws->SubscriptionID
    func receive(id:SubscriptionID)async throws->Data
    func unsubscribe(id:SubscriptionID)async
    func cancel()async
}

/// Short critical sections only; cancellation closures execute after unlocking. Bound includes active
/// HTTP requests and sockets; refusal never prunes retained credentials or mutates immutable storage.
private final class GenericWorkDomain:@unchecked Sendable {
    private let mutex=NSLock()
    private var cancelled=false
    private var work:[UUID:GenericCancellation]=[:]
    func check()throws {try Task.checkCancellation();mutex.lock();defer{mutex.unlock()};guard !cancelled else {throw ConnectionFailure.permissionRequired}}
    func begin()throws->(UUID,GenericCancellation) {
        try Task.checkCancellation();mutex.lock();defer{mutex.unlock()}
        guard !cancelled,work.count < 128 else {throw ConnectionFailure.permissionRequired}
        let id=UUID(),latch=GenericCancellation();work[id]=latch;return(id,latch)
    }
    func end(_ id:UUID) {mutex.lock();work.removeValue(forKey:id);mutex.unlock()}
    func cancel() {
        mutex.lock();cancelled=true;let items=Array(work.values);work.removeAll();mutex.unlock()
        for item in items {item.cancel()}
    }
}
private final class GenericCancellation:@unchecked Sendable {
    private let mutex=NSLock()
    private var cancelled=false
    private var action:(@Sendable ()->Void)?
    func install(_ action:@escaping @Sendable ()->Void) {
        mutex.lock();let now=cancelled;self.action=now ? nil:action;mutex.unlock();if now {action()}
    }
    func check()throws {try Task.checkCancellation();mutex.lock();defer{mutex.unlock()};guard !cancelled else {throw ConnectionFailure.permissionRequired}}
    func cancel() {mutex.lock();cancelled=true;let invoke=action;action=nil;mutex.unlock();invoke?()}
}
private struct ImmutableHTTP:HTTPTransport {
    let delegate:any HTTPTransport
    let authorization:DeviceImmutableGenericAuthorization
    let domain:GenericWorkDomain
    func send(_ request:AuthorizedHTTPRequest)async throws->HTTPTransportResponse {
        let(id,latch)=try domain.begin();defer{domain.end(id)}
        let reservation=try authorization.reserve(onCancel:{latch.cancel()});defer{reservation.finish()}
        try domain.check();try latch.check();try reservation.check()
        return try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation();try latch.check()
            let task=Task {
                try Task.checkCancellation();try latch.check();try domain.check();try reservation.check()
                return try await delegate.send(request)
            }
            latch.install {task.cancel()}
            let result=try await task.value
            try latch.check();try domain.check();try reservation.check();try authorization.validate()
            return result
        },onCancel:{latch.cancel()})
    }
}
private struct ImmutableWebSocket:WebSocketTransport {
    let delegate:any WebSocketTransport
    let authorization:DeviceImmutableGenericAuthorization
    let domain:GenericWorkDomain
    func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession {
        let(id,latch)=try domain.begin()
        do {
            let reservation=try authorization.reserve(onCancel:{latch.cancel()})
            var handedOff=false
            do {
                try domain.check();try latch.check();try reservation.check()
                let session=try await withTaskCancellationHandler(operation:{
                    try Task.checkCancellation();try latch.check()
                    let task=Task {
                        try Task.checkCancellation();try latch.check();try domain.check();try reservation.check()
                        return try await delegate.connect(request)
                    }
                    latch.install {task.cancel()};return try await task.value
                },onCancel:{latch.cancel()})
                handedOff=true
                let wrapped=ImmutableSession(session:session,authorization:authorization,domain:domain,id:id,latch:latch,reservation:reservation)
                latch.install {Task {await wrapped.close()}}
                do {try wrapped.check();return wrapped} catch {await wrapped.close();throw error}
            } catch {if !handedOff {reservation.finish()};throw error}
        } catch {domain.end(id);throw error}
    }
}
private actor ImmutableSession:WebSocketSession {
    private let session:any WebSocketSession
    private let authorization:DeviceImmutableGenericAuthorization
    private let domain:GenericWorkDomain
    private let id:UUID
    private let latch:GenericCancellation
    private let reservation:any DeviceImmutableGenericReservation
    private var closeTask:Task<Void,Never>?
    init(session:any WebSocketSession,authorization:DeviceImmutableGenericAuthorization,domain:GenericWorkDomain,id:UUID,latch:GenericCancellation,reservation:any DeviceImmutableGenericReservation) {
        self.session=session;self.authorization=authorization;self.domain=domain;self.id=id;self.latch=latch;self.reservation=reservation
    }
    nonisolated func check()throws {try domain.check();try latch.check();try reservation.check();try authorization.validate()}
    func receive()async throws->Data {
        try check()
        do {let bytes=try await withTaskCancellationHandler(operation:{try self.check();return try await session.receive()},onCancel:{self.latch.cancel()});try check();return bytes}
        catch {await close();try Task.checkCancellation();throw error}
    }
    func send(_ data:Data)async throws {
        try check()
        do{try await withTaskCancellationHandler(operation:{try self.check();try await session.send(data)},onCancel:{self.latch.cancel()});try check()}
        catch{await close();try Task.checkCancellation();throw error}
    }
    func sendText(_ text:String)async throws {
        try check()
        do{try await withTaskCancellationHandler(operation:{try self.check();try await session.sendText(text)},onCancel:{self.latch.cancel()});try check()}
        catch{await close();try Task.checkCancellation();throw error}
    }
    func close()async {
        if let closeTask {await closeTask.value;return}
        reservation.finish();domain.end(id)
        let task=Task {await session.close()};closeTask=task
        latch.cancel();await task.value
    }
}

/// Only operation methods escape. The actor/store are private; clearCredentials affects this memory
/// working set only. No public-read/HA adapter, mutable install method, backend writer or secret getter.
final class DeviceImmutableGenericFacade:DeviceImmutableGenericOperations,GrantSecretRedacted,@unchecked Sendable {
    private let runtime:ConnectionRuntime
    private let authorization:DeviceImmutableGenericAuthorization
    private let domain:GenericWorkDomain
    private init(runtime:ConnectionRuntime,authorization:DeviceImmutableGenericAuthorization,domain:GenericWorkDomain) {
        self.runtime=runtime;self.authorization=authorization;self.domain=domain
    }
    static func install(_ provisioning:ConnectionProvisioning,authorization:DeviceImmutableGenericAuthorization,
                        http:any HTTPTransport,webSocket:any WebSocketTransport,resolver:any DestinationResolver,clock:any PairingClock)async throws->any DeviceImmutableGenericOperations {
        try Task.checkCancellation();try authorization.validate();try provisioning.validate()
        let memory=MemoryCredentialStore(),domain=GenericWorkDomain()
        let runtime=ConnectionRuntime(dashboardId:provisioning.dashboardId,store:memory,
            http:ImmutableHTTP(delegate:http,authorization:authorization,domain:domain),
            webSocket:ImmutableWebSocket(delegate:webSocket,authorization:authorization,domain:domain),
            resolver:resolver,clock:clock,authorizeScope:{try domain.check();try authorization.validate()})
        do {
            for item in provisioning.entries {
                try Task.checkCancellation()
                if let secret=item.secret {try memory.put(secret,for:item.binding.authRef)}
                try await runtime.install(grant:item.grant,binding:item.binding)
            }
            try authorization.validate();try domain.check()
            return DeviceImmutableGenericFacade(runtime:runtime,authorization:authorization,domain:domain)
        } catch {domain.cancel();try? await runtime.clearCredentials();try Task.checkCancellation();throw error}
    }
    private func check()throws {try domain.check();try authorization.validate()}
    func request(alias:String,operation:String,parameters:[String:String])async throws->ConnectionHTTPResult {
        try check()
        do{let result=try await runtime.request(alias:alias,operation:operation,parameters:parameters);try check();return result}
        catch{try Task.checkCancellation();throw error}
    }
    func requestRead(alias:String,operation:String,parameters:[String:String])async throws->ConnectionHTTPResult {
        try check()
        do{let result=try await runtime.requestRead(alias:alias,operation:operation,parameters:parameters);try check();return result}
        catch{try Task.checkCancellation();throw error}
    }
    func subscribe(alias:String,operation:String,parameters:[String:String])async throws->SubscriptionID {
        try check()
        let id:SubscriptionID
        do{id=try await runtime.subscribe(alias:alias,operation:operation,parameters:parameters)}catch{try Task.checkCancellation();throw error}
        do{try check();return id}catch{await runtime.unsubscribe(id:id);try Task.checkCancellation();throw error}
    }
    func receive(id:SubscriptionID)async throws->Data {
        try check()
        do{let bytes=try await runtime.receive(id:id);try check();return bytes}catch{try Task.checkCancellation();throw error}
    }
    func unsubscribe(id:SubscriptionID)async {await runtime.unsubscribe(id:id)}
    func cancel()async {domain.cancel();try? await runtime.clearCredentials()}
}
