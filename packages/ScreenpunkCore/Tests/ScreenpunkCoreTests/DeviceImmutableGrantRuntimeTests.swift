import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import ScreenpunkCore

final class DeviceImmutableGrantRuntimeTests: XCTestCase {
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String:DeviceGrantCredentialValue] = [:], adds = 0
        var onRead: (() throws -> Void)?
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws { for key in values.keys.sorted() { try visit(values[key]!.item) } }
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? { try onRead?(); return values[account] }
        func add(service:String,account:String,bytes:Data)throws->DeviceGrantCredentialItem {
            guard values[account] == nil else { throw DeviceGrantPreparationError.conflict }; adds += 1
            let item = DeviceGrantCredentialItem(account:account,persistentReference:Data("ref-\(adds)".utf8),byteCount:bytes.count)
            values[account] = .init(item:item,bytes:bytes); return item
        }
    }
    private func id(_ n:Int)->UUID { UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))! }
    private var owner:PairingIdentity { .init(role:.controller,publicKey:[UInt8](repeating:7,count:32)) }
    private func environment()throws->(URL,DevicePackageProtectedScope) {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil)); defer { free(physical) }
        let root = URL(fileURLWithPath:String(cString:physical),isDirectory:true).appendingPathComponent("complete-set-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        for name in ["structural","packages","grants","legacy","archive","reset","cloud","management","preferences"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false) }
        return (root,.init(legacyStateRoot:root.appendingPathComponent("legacy"),legacyArchiveRoot:root.appendingPathComponent("archive"),resetRoot:root.appendingPathComponent("reset"),cloudRoot:root.appendingPathComponent("cloud"),managementRoot:root.appendingPathComponent("management"),preferencesRoot:root.appendingPathComponent("preferences"),otherProtectedRoots:[]))
    }
    private struct Fixture {
        let root:URL; let packages:DevicePackagePreparationStore; let grants:DeviceGrantPreparationStore; let backend:Backend
        let request:DeviceLocalCompleteSetRequest
        let structural:DeviceStructuralStore
        let scope:DevicePackageProtectedScope
        var commit:DeviceLocalCompleteSetCommitCoordinator { .init(packageStore:packages,grantStore:grants,structuralStore:structural) }
        var coordinator:DeviceLocalCompleteSetCoordinator { .init(packageStore:packages,grantStore:grants) }
    }

    private enum Marker:Error { case injected }
    private final class Fault { var target:DeviceStructuralStore.Boundary?;var hit=false;var hook:(()throws->Void)?;var boundaryHook:((DeviceStructuralStore.Boundary)throws->Void)? }
    private func fixtureEmpty(_ fault:Fault = Fault())throws->Fixture {
        let env = try environment(), backend = Backend()
        let packages = DevicePackagePreparationStore(root:env.0.appendingPathComponent("packages"),rootID:id(1),protectedScope:env.1)
        let grants = DeviceGrantPreparationStore(root:env.0.appendingPathComponent("grants"),rootID:id(2),protectedScope:env.1,backend:backend)
        let structural=DeviceStructuralStore(root:env.0.appendingPathComponent("structural"),rootID:id(5),boundary:{ point in
            try fault.hook?();try fault.boundaryHook?(point)
            if fault.target == point { fault.target=nil;fault.hit=true;throw Marker.injected }
        })
        try packages.initializeExplicit(); try grants.initializeExplicit();try structural.initializeExplicit()
        let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(3)),owner:owner,entries:[],credentials:[],retainedRevisions:[])
        let grant = DeviceGrantPreparationRequest(operationID:id(4),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        let receipt = try grants.prepareExact(grant)
        return .init(root:env.0,packages:packages,grants:grants,backend:backend,request:.init(structuralRootID:id(5),operationID:id(6),expectedGenerationID:nil,
            baseline:.initialExplicit(legacyGrantSet:"opaque-legacy"),snapshot:.init(generationID:id(7),entries:[],configuredEntryID:nil,contentOwner:owner,grantSet:"opaque-legacy"),packages:[],grantReceipt:receipt,grantRequest:grant,owner:owner),structural:structural,scope:env.1)
    }

    private func group(_ r:DeviceLocalCompleteSetRequest)->DeviceRetainedGrantResolutionGroup {
        .init(reference:.init(identity:r.grantReceipt.identity,operationID:r.grantReceipt.operationID),expectedOwner:r.owner,
              packages:r.packages.map{.init(entryID:$0.entryID,reference:$0.receipt.reference)})
    }
    private func gate(_ f:Fixture)->DeviceLocalResourceGate { .init(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural) }
    private func restore(_ f:Fixture)->DeviceLocalCompleteSetRestoreCoordinator { .init(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural) }

    private func resolve(_ f:Fixture)throws->DeviceResolvedRetainedResources {
        try DeviceRetainedResourceResolver(packageStore:f.packages,grantStore:f.grants,structuralStore:f.structural).resolveTerminalExact(selected:group(f.request).reference,groups:[group(f.request)])
    }

    #if canImport(CryptoKit)
    private func encode<T:Encodable>(_ value:T)throws->Data { let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value) }
    private func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    private func package(_ n:Int,ws:Bool=false)throws->QualifiedDevicePackage {
        let file = Data("<html></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(n).uuidString.lowercased(),name:"Package",revision:id(n+100).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",
            target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:ws ? "ws":"http")])],files:[.init(path:"index.html",bytes:file.count,sha256:hash(file))])
        manifest.digest=hash(try encode(manifest))
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:file)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
    }
    private func populated(_ secret:Data=Data("PRIVATE_TRANSACTION_CANARY".utf8),ws:Bool=false,fault:Fault=Fault())throws->Fixture {
        let empty = try fixtureEmpty(fault); var bindings:[DeviceLocalCompleteSetPackageBinding]=[],entries:[DeviceStructuralEntry]=[],expected:[DeviceGrantEntryExpectation]=[],grants:[DeviceGrantEntryInput]=[]
        for n in [10,20] {
            let package=try package(n,ws:ws),receipt=try empty.packages.prepareExact(.init(operationID:id(n+200),package:package))
            bindings.append(.init(entryID:id(n),receipt:receipt));entries.append(.init(entryID:id(n),displayName:"Household \(n)",revision:package.revision,packageDirectory:receipt.reference.directory));expected.append(.init(entryID:id(n),package:package))
            let grant=ConnectionGrant(schemaVersion:1,id:id(n+300),alias:"api",origin:"https://example.com",transport:ws ? .ws:.http,authRef:"shared-logical",lan:false,allowInsecureHTTP:false,operations:[.init(name:"read",kind:ws ? .ws:.http,method:.GET,path:"/states",idempotent:true,write:false)])
            let config=ConnectionProvisioning(dashboardId:package.revision.dashboardId,revision:package.revision.revision,provisioningId:"supplied-approval",entries:[.init(grant:grant,binding:.init(authRef:grant.authRef,placement:.bearer),secret:secret)])
            grants.append(.init(entryID:id(n),revision:package.revision,generic:config,homeAssistant:nil,publicReads:nil,credentialReferences:[.init(credentialRevisionID:id(400),kind:.generic,key:"shared-logical")]))
        }
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(401)),owner:owner,entries:grants,credentials:[.init(revisionID:id(400),bytes:secret)],retainedRevisions:[empty.request.grantRequest.input.identity])
        let request=DeviceGrantPreparationRequest(operationID:id(402),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expected),expectedEntries:expected)
        let receipt=try empty.grants.prepareExact(request)
        return .init(root:empty.root,packages:empty.packages,grants:empty.grants,backend:empty.backend,request:.init(structuralRootID:id(5),operationID:id(403),expectedGenerationID:nil,baseline:.initialExplicit(legacyGrantSet:nil),snapshot:.init(generationID:id(404),entries:entries,configuredEntryID:id(20),contentOwner:owner,grantSet:nil),packages:bindings,grantReceipt:receipt,grantRequest:request,owner:owner),structural:empty.structural,scope:empty.scope)
    }

    #endif

    private struct Resolver:DestinationResolver {func addresses(for host:String)throws->[String]{["93.184.216.34"]}}
    private final class Driver:DeviceImmutableGenericAdmissionDriver,@unchecked Sendable {
        let mutex=NSLock();var revoked=false;var mode=1;var validations=0
        var hook:(()throws->Void)?;var cancellation:[@Sendable ()->Void]=[]
        final class Reservation:DeviceImmutableGenericReservation,@unchecked Sendable {
            let driver:Driver;init(_ driver:Driver){self.driver=driver}
            func check()throws{driver.mutex.lock();let revoked=driver.revoked;driver.mutex.unlock();if revoked{throw ConnectionFailure.permissionRequired}}
            func finish(){}
        }
        func reserve(scope:DeviceImmutableGenericScope,validateResources:()throws->Void,onCancel:@escaping @Sendable ()->Void)throws->any DeviceImmutableGenericReservation {
            try DeviceLocalResourceRegistry.requireIdle()
            validations += 1;try hook?()
            if mode == 1 {try validateResources()}
            if mode == 2 {try? validateResources();try? validateResources()}
            if mode == 3 {try? validateResources()}
            mutex.lock();cancellation.append(onCancel);mutex.unlock()
            return Reservation(self)
        }
        func revoke(){mutex.lock();revoked=true;let callbacks=cancellation;mutex.unlock();for callback in callbacks{callback()}}
    }
    private final class HTTP:HTTPTransport,@unchecked Sendable {
        var calls=0;var headers:[String:String]=[:];var hook:(()async throws->Void)?
        func send(_ request:AuthorizedHTTPRequest)async throws->HTTPTransportResponse {
            calls += 1;headers=request.headers;try await hook?();return .init(status:200,body:Data("approved response".utf8))
        }
    }
    private struct Socket:WebSocketTransport {
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession {throw ConnectionFailure.permissionRequired}
    }
    private func denied(_ body:()async throws->Void,file:StaticString=#filePath,line:UInt=#line)async {
        do{try await body();XCTFail("Expected refusal",file:file,line:line)}catch{}
    }
    func testEmptyRestoredSetHasFreshCaptureButNoGenericEntry()async throws {
        let f=try fixtureEmpty();_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact()
        try gate(f).withReadScope{try $0.verifyQualifiedStructuralCapture(ack.runtimeBinding.capture)}
        await denied{_ = try await self.gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:self.id(10),admission:Driver(),http:HTTP(),webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
        _ = try f.structural.recommitExact(operationID:f.request.operationID)
        XCTAssertThrowsError(try gate(f).withReadScope{try $0.verifyQualifiedStructuralCapture(ack.runtimeBinding.capture)})
    }
    func testUncertainStructuralRecommitRejectsRestoreAcknowledgment()throws {
        let fault=Fault(),f=try fixtureEmpty(fault);_ = try f.commit.commitPreparedExact(f.request)
        var hits=0
        fault.hook={hits += 1}
        fault.target = .afterReplace(.terminal)
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertTrue(fault.hit)
        fault.hook=nil
        XCTAssertNoThrow(try restore(f).restoreLatestTerminalExact())
    }
    #if canImport(CryptoKit)
    private func runtime(_ f:Fixture,_ driver:Driver=Driver(),_ http:HTTP=HTTP())async throws->any DeviceImmutableGenericOperations {
        let ack=try restore(f).restoreLatestTerminalExact()
        return try await gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:id(10),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())
    }
    func testOneEntrySharedCredentialOperationsAndMemoryOnlyCancellation()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let driver=Driver(),http=HTTP(),adds=f.backend.adds,api=try await runtime(f,driver,http)
        let result=try await api.requestRead(alias:"api",operation:"read",parameters:[:])
        XCTAssertEqual(result.body,Data("approved response".utf8));XCTAssertEqual(http.headers["Authorization"],"Bearer PRIVATE_TRANSACTION_CANARY")
        XCTAssertEqual(http.calls,1);XCTAssertGreaterThan(driver.validations,3)
        XCTAssertFalse(String(describing:api).contains("PRIVATE_TRANSACTION_CANARY"));XCTAssertTrue(Mirror(reflecting:api).children.isEmpty)
        await api.cancel();XCTAssertEqual(f.backend.adds,adds)
        await denied{_ = try await api.request(alias:"api",operation:"read",parameters:[:])}
        XCTAssertEqual(http.calls,1)
    }
    func testMandatoryDriverMissingAndDoubleValidationRejectBeforeTransport()async throws {
        for mode in [0,2] {
            let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
            let driver=Driver(),http=HTTP();driver.mode=mode
            await denied{_ = try await self.runtime(f,driver,http)};XCTAssertEqual(http.calls,0)
        }
    }
    func testDriverSwallowedStaleValidationCannotInstall()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),driver=Driver();driver.mode=3
        _ = try f.structural.recommitExact(operationID:f.request.operationID)
        await denied{_ = try await self.gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:self.id(10),admission:driver,http:HTTP(),webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
    }
    func testRevocationDuringHTTPRejectsResponseAndCacheWithoutBackendEffects()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let driver=Driver(),http=HTTP(),api=try await runtime(f,driver,http),adds=f.backend.adds
        _ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])
        http.hook={driver.revoke()}
        await denied{_ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])}
        await denied{_ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])}
        XCTAssertEqual(http.calls,2);XCTAssertEqual(f.backend.adds,adds)
    }
    func testSameTipStructuralRecommitAndResourceRecommitInvalidateFacade()async throws {
        for resource in [false,true] {
            let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
            let http=HTTP(),api=try await runtime(f,Driver(),http)
            if resource {_ = try f.grants.recommitExact(f.request.grantRequest)}else{_ = try f.structural.recommitExact(operationID:f.request.operationID)}
            await denied{_ = try await api.request(alias:"api",operation:"read",parameters:[:])};XCTAssertEqual(http.calls,0)
        }
    }
    func testWrongEntryAndActorInstallMutationRefuse()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),driver=Driver()
        await denied{_ = try await self.gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:self.id(999),admission:driver,http:HTTP(),webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
        var calls=0;driver.hook={calls += 1;if calls == 2 {_ = try f.structural.recommitExact(operationID:f.request.operationID)}}
        await denied{_ = try await self.gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:self.id(10),admission:driver,http:HTTP(),webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
    }

    private final class FakeSession:WebSocketSession,@unchecked Sendable {
        private let mutex=NSLock();private var closeCount=0;private var callback:(()async throws->Void)?
        var closes:Int{mutex.lock();defer{mutex.unlock()};return closeCount}
        var hook:(()async throws->Void)?{get{mutex.lock();defer{mutex.unlock()};return callback}set{mutex.lock();callback=newValue;mutex.unlock()}}
        func receive()async throws->Data{let callback=hook;try await callback?();return Data("message".utf8)}
        func send(_ bytes:Data)async throws{}
        private func recordClose(){mutex.lock();closeCount += 1;mutex.unlock()}
        func close()async{recordClose()}
    }
    private struct FakeSockets:WebSocketTransport {
        let session:FakeSession
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession{session}
    }
    func testSocketRevocationDropsMessageAndClosesWithoutPrivateMutation()async throws {
        let f=try populated(ws:true);_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),driver=Driver(),session=FakeSession(),adds=f.backend.adds
        let api=try await gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:id(10),admission:driver,http:HTTP(),webSocket:FakeSockets(session:session),resolver:Resolver(),clock:SystemClock())
        let subscription=try await api.subscribe(alias:"api",operation:"read",parameters:[:])
        let message=try await api.receive(id:subscription);XCTAssertEqual(message,Data("message".utf8))
        session.hook={driver.revoke()}
        await denied{_ = try await api.receive(id:subscription)}
        await api.unsubscribe(id:subscription);XCTAssertGreaterThanOrEqual(session.closes,1)
        await api.cancel();XCTAssertEqual(f.backend.adds,adds)
    }
    func testDriverCalledOutsideGateAndBackendCannotReenterAdmission()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let driver=Driver(),http=HTTP();driver.hook={try DeviceLocalResourceRegistry.requireIdle()}
        let api=try await runtime(f,driver,http)
        var observed=false
        f.backend.onRead={observed=true;XCTAssertThrowsError(try DeviceLocalResourceRegistry.requireIdle())}
        _ = try await api.request(alias:"api",operation:"read",parameters:[:]);XCTAssertTrue(observed)
    }

    func testMaximumSecretAndOneEntrySeedAreRedacted()async throws {
        let f=try populated(Data(repeating:65,count:8192));_ = try f.commit.commitPreparedExact(f.request)
        let http=HTTP(),api=try await runtime(f,Driver(),http)
        _ = try await api.request(alias:"api",operation:"read",parameters:[:]);XCTAssertEqual(http.headers["Authorization"]?.utf8.count,8199)
        let bundle=try resolve(f),seed=try gate(f).withReadScope{try $0.genericSeed(bundle.grantReceipts.first(where:{$0.identity == bundle.selected.identity})!,expectedEntries:f.request.grantRequest.expectedEntries,owner:owner,entryID:id(10))}
        XCTAssertTrue(Mirror(reflecting:seed).children.isEmpty);XCTAssertFalse(String(reflecting:seed).contains(String(repeating:"A",count:100)))
        await api.cancel()
    }
    func testBackendReplacementDuringRestoreRecommitCannotAcknowledge()throws {
        let fault=Fault(),f=try populated(fault:fault);_ = try f.commit.commitPreparedExact(f.request)
        var changed=false
        fault.boundaryHook={point in
            if !changed,point == .afterDirectorySync(.terminal) {
                changed=true
                let key=f.backend.values.keys.sorted().first!,old=f.backend.values[key]!
                f.backend.values[key] = .init(item:old.item,bytes:Data(repeating:65,count:old.bytes.count))
            }
        }
        XCTAssertThrowsError(try restore(f).restoreLatestTerminalExact());XCTAssertTrue(changed)
    }

    private actor Pause {
        private var entered=false
        private var observer:CheckedContinuation<Void,Never>?
        private var release:CheckedContinuation<Void,Never>?
        func wait()async{entered=true;observer?.resume();observer=nil;await withCheckedContinuation{release=$0}}
        func awaitEntry()async{if entered{return};await withCheckedContinuation{observer=$0}}
        func resume(){release?.resume();release=nil}
    }
    func testCancelWhileHTTPIsAdmittedDropsLateResponse()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let pause=Pause(),http=HTTP(),api=try await runtime(f,Driver(),http)
        http.hook={await pause.wait()}
        let pending=Task{try await api.request(alias:"api",operation:"read",parameters:[:])}
        await pause.awaitEntry();await api.cancel();await pause.resume()
        await denied{_ = try await pending.value};XCTAssertEqual(http.calls,1)
        // Work had been admitted before cancellation; suppressing its response cannot undo packets.
    }
    private struct PausedSocket:WebSocketTransport {
        let pause:Pause;let session:FakeSession
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession{await pause.wait();return session}
    }
    func testCancelWhileSocketConnectIsAdmittedClosesLateSession()async throws {
        let f=try populated(ws:true);_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),pause=Pause(),session=FakeSession()
        let api=try await gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:id(10),admission:Driver(),http:HTTP(),webSocket:PausedSocket(pause:pause,session:session),resolver:Resolver(),clock:SystemClock())
        let pending=Task{try await api.subscribe(alias:"api",operation:"read",parameters:[:])}
        await pause.awaitEntry();await api.cancel();await pause.resume()
        await denied{_ = try await pending.value};XCTAssertGreaterThanOrEqual(session.closes,1)
    }

    private func cancelled(_ body:()async throws->Void,file:StaticString=#filePath,line:UInt=#line)async {
        do{try await body();XCTFail("Canceled caller returned a result",file:file,line:line)}
        catch is CancellationError {} catch {XCTFail("Expected caller cancellation, got \(error)",file:file,line:line)}
    }
    func testCallerTaskCancellationCannotReturnPrimedCache()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let pause=Pause(),http=HTTP(),api=try await runtime(f,Driver(),http)
        _ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])
        http.hook={await pause.wait()}
        let pending=Task{try await api.requestRead(alias:"api",operation:"read",parameters:[:])}
        await pause.awaitEntry();pending.cancel();await pause.resume()
        await cancelled{_ = try await pending.value};XCTAssertEqual(http.calls,2)
        http.hook=nil
        let stillUsable=try await api.requestRead(alias:"api",operation:"read",parameters:[:])
        XCTAssertFalse(stillUsable.stale);XCTAssertEqual(http.calls,3)
        await api.cancel()
    }
    func testPreCanceledCallerRequestDoesNotDispatchOrReturnCache()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let http=HTTP(),api=try await runtime(f,Driver(),http)
        _ = try await api.requestRead(alias:"api",operation:"read",parameters:[:])
        let pending=Task{withUnsafeCurrentTask{$0?.cancel()};return try await api.requestRead(alias:"api",operation:"read",parameters:[:])}
        await cancelled{_ = try await pending.value};XCTAssertEqual(http.calls,1)
        await api.cancel()
    }
    func testPreCanceledCallerFactoryReturnsNoFacade()async throws {
        let f=try populated();_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),driver=Driver(),http=HTTP()
        let pending=Task{withUnsafeCurrentTask{$0?.cancel()};return try await self.gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:self.id(10),admission:driver,http:http,webSocket:Socket(),resolver:Resolver(),clock:SystemClock())}
        await cancelled{_ = try await pending.value};XCTAssertEqual(http.calls,0);XCTAssertEqual(driver.validations,0)
    }
    func testCallerTaskCanceledConnectClosesLateSession()async throws {
        let f=try populated(ws:true);_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),pause=Pause(),session=FakeSession()
        let api=try await gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:id(10),admission:Driver(),http:HTTP(),webSocket:PausedSocket(pause:pause,session:session),resolver:Resolver(),clock:SystemClock())
        let pending=Task{try await api.subscribe(alias:"api",operation:"read",parameters:[:])}
        await pause.awaitEntry();pending.cancel();await pause.resume()
        await cancelled{_ = try await pending.value};XCTAssertEqual(session.closes,1)
        await api.cancel()
    }
    private final class RestartableSockets:WebSocketTransport,@unchecked Sendable {
        private let mutex=NSLock();private var sessions:[FakeSession]=[]
        var calls:Int{mutex.lock();defer{mutex.unlock()};return sessions.count}
        var first:FakeSession?{mutex.lock();defer{mutex.unlock()};return sessions.first}
        private func add()->FakeSession{mutex.lock();defer{mutex.unlock()};let session=FakeSession();sessions.append(session);return session}
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession{add()}
    }
    func testCallerTaskCanceledReceiveDropsLateMessageAndCloses()async throws {
        let f=try populated(ws:true);_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),pause=Pause(),sockets=RestartableSockets()
        let api=try await gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:id(10),admission:Driver(),http:HTTP(),webSocket:sockets,resolver:Resolver(),clock:SystemClock())
        let subscription=try await api.subscribe(alias:"api",operation:"read",parameters:[:]),session=try XCTUnwrap(sockets.first)
        session.hook={await pause.wait()}
        let pending=Task{try await api.receive(id:subscription)}
        await pause.awaitEntry();pending.cancel();await pause.resume()
        await cancelled{_ = try await pending.value};XCTAssertEqual(session.closes,1)
        let fresh=try await api.subscribe(alias:"api",operation:"read",parameters:[:])
        XCTAssertNotEqual(fresh,subscription);XCTAssertEqual(sockets.calls,2)
        await api.unsubscribe(id:fresh);await api.cancel()
    }

    private final class CountingSocket:WebSocketTransport,@unchecked Sendable {
        private let mutex=NSLock();private var count=0
        let session=FakeSession()
        var calls:Int{mutex.lock();defer{mutex.unlock()};return count}
        private func record(){mutex.lock();count += 1;mutex.unlock()}
        func connect(_ request:AuthorizedWebSocketRequest)async throws->any WebSocketSession{record();return session}
    }
    func testPreCanceledCallerSubscribeDoesNotConnect()async throws {
        let f=try populated(ws:true);_ = try f.commit.commitPreparedExact(f.request)
        let ack=try restore(f).restoreLatestTerminalExact(),socket=CountingSocket()
        let api=try await gate(f).makeGenericRuntimeExact(binding:ack.runtimeBinding,entryID:id(10),admission:Driver(),http:HTTP(),webSocket:socket,resolver:Resolver(),clock:SystemClock())
        let pending=Task{withUnsafeCurrentTask{$0?.cancel()};return try await api.subscribe(alias:"api",operation:"read",parameters:[:])}
        await cancelled{_ = try await pending.value};XCTAssertEqual(socket.calls,0);await api.cancel()
    }
    #endif
}
