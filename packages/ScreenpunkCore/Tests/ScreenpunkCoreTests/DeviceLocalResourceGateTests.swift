import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import ScreenpunkCore
#if canImport(CryptoKit)
import CryptoKit
#endif

final class DeviceLocalResourceGateTests: XCTestCase {
    private enum Marker: Error { case injected }
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String:DeviceGrantCredentialValue] = [:]
        var onRead: (() throws -> Void)?
        var adds = 0
        func inventory(service:String,maximum:Int,visit:(DeviceGrantCredentialItem)throws->Void)throws { for key in values.keys.sorted() { try visit(values[key]!.item) } }
        func read(service:String,account:String,maximumBytes:Int)throws->DeviceGrantCredentialValue? { try onRead?(); return values[account] }
        func add(service:String,account:String,bytes:Data)throws->DeviceGrantCredentialItem {
            guard values[account] == nil else { throw Marker.injected }; adds += 1
            let item=DeviceGrantCredentialItem(account:account,persistentReference:Data("ref-\(adds)".utf8),byteCount:bytes.count)
            values[account] = .init(item:item,bytes:bytes);return item
        }
    }
    private final class Box<T>: @unchecked Sendable {
        private let lock=NSLock(); private var stored:T
        init(_ value:T) { stored=value }
        var value:T { get { lock.lock();defer{lock.unlock()};return stored } set { lock.lock();defer{lock.unlock()};stored=newValue } }
    }
    private struct Fixture {
        let root:URL;let scope:DevicePackageProtectedScope;let packages:DevicePackagePreparationStore
        let grants:DeviceGrantPreparationStore;let structural:DeviceStructuralStore;let backend:Backend
        let request:DeviceGrantPreparationRequest;let receipt:DevicePreparedGrantReceipt
        var gate:DeviceLocalResourceGate { .init(packageStore:packages,grantStore:grants,structuralStore:structural) }
        var locks:[URL] { [root.appendingPathComponent("a-grants/preparation.lock"),root.appendingPathComponent("m-structural/structural.lock"),root.appendingPathComponent("z-packages/preparation.lock")] }
    }
    private func id(_ n:Int)->UUID { UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))! }
    private func environment()throws->(URL,DevicePackageProtectedScope) {
        let physical=try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil));defer{free(physical)}
        let root=URL(fileURLWithPath:String(cString:physical),isDirectory:true).appendingPathComponent("resource-gate-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false);addTeardownBlock { try? FileManager.default.removeItem(at:root) }
        for name in ["a-grants","m-structural","z-packages","legacy","archive","reset","cloud","management","preferences"] { try FileManager.default.createDirectory(at:root.appendingPathComponent(name),withIntermediateDirectories:false) }
        return (root,.init(legacyStateRoot:root.appendingPathComponent("legacy"),legacyArchiveRoot:root.appendingPathComponent("archive"),resetRoot:root.appendingPathComponent("reset"),cloudRoot:root.appendingPathComponent("cloud"),managementRoot:root.appendingPathComponent("management"),preferencesRoot:root.appendingPathComponent("preferences"),otherProtectedRoots:[]))
    }
    private func fixture()throws->Fixture {
        let env=try environment(),backend=Backend()
        let packages=DevicePackagePreparationStore(root:env.0.appendingPathComponent("z-packages"),rootID:id(1),protectedScope:env.1)
        let grants=DeviceGrantPreparationStore(root:env.0.appendingPathComponent("a-grants"),rootID:id(2),protectedScope:env.1,backend:backend)
        let structural=DeviceStructuralStore(root:env.0.appendingPathComponent("m-structural"),rootID:id(3))
        try packages.initializeExplicit();try grants.initializeExplicit();try structural.initializeExplicit()
        let input=DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(2),revisionID:id(4)),owner:.init(role:.controller,publicKey:[UInt8](repeating:7,count:32)),entries:[],credentials:[],retainedRevisions:[])
        let request=DeviceGrantPreparationRequest(operationID:id(5),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        return .init(root:env.0,scope:env.1,packages:packages,grants:grants,structural:structural,backend:backend,request:request,receipt:try grants.prepareExact(request))
    }
    private func assertGateError(_ operation:()throws->Void,file:StaticString=#filePath,line:UInt=#line) {
        XCTAssertThrowsError(try operation(),file:file,line:line) { XCTAssertTrue($0 is DeviceLocalResourceGateFailure,"Unexpected: \($0)",file:file,line:line) }
    }
    private func assertBusy(_ path:URL)throws {
        let fd=open(path.path,O_RDWR|O_NOFOLLOW);guard fd >= 0 else { throw Marker.injected };defer{close(fd)}
        let result=flock(fd,LOCK_EX|LOCK_NB)
        if result == 0 { _=flock(fd,LOCK_UN) }
        XCTAssertEqual(result,-1);XCTAssertTrue(errno == EWOULDBLOCK || errno == EAGAIN)
    }
    private func assertReleased(_ path:URL)throws {
        let fd=open(path.path,O_RDWR|O_NOFOLLOW);guard fd >= 0 else { throw Marker.injected };defer{close(fd)}
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0);_ = flock(fd,LOCK_UN)
    }
    func testAllExistingLocksHeldAndScopedReadDoesNotChangeOrQualifyState()throws {
        let f=try fixture(),before=try Data(contentsOf:f.root.appendingPathComponent("a-grants/head.json")),adds=f.backend.adds
        let result=try f.gate.withReadScope { scope -> DeviceGrantRevisionIdentity in
            for path in f.locks { try assertBusy(path) }
            return try scope.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[]).identity
        }
        XCTAssertEqual(result,f.request.input.identity);XCTAssertEqual(f.backend.adds,adds)
        XCTAssertEqual(try Data(contentsOf:f.root.appendingPathComponent("a-grants/head.json")),before)
        for path in f.locks { try assertReleased(path) }
        let nilResult:Int?=try f.gate.withReadScope {_ in nil};XCTAssertNil(nilResult)
    }
    func testOrdinaryAndNestedGateCallsRejectBeforeMutexAndMutation()throws {
        let f=try fixture(),adds=f.backend.adds
        try f.gate.withReadScope { scope in
            assertGateError { try f.packages.initializeExplicit() };assertGateError { try f.grants.initializeExplicit() };assertGateError { try f.structural.initializeExplicit() }
            assertGateError { _=try f.grants.prepareExact(f.request) };assertGateError { _=try f.grants.recommitExact(f.request) }
            assertGateError { _=try f.grants.verify(f.receipt) };assertGateError { _=try f.packages.diagnose(operationID:id(999)) }
            assertGateError { _=try f.gate.withReadScope {_ in 1} }
            XCTAssertEqual(try scope.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[]).identity,f.request.input.identity)
        }
        XCTAssertEqual(f.backend.adds,adds);XCTAssertNoThrow(try f.grants.verify(f.receipt))
    }
    func testNestedBackendOrdinaryAndCapturedScopeReadsRejectAndThrowCleansUp()throws {
        let f=try fixture();var active:DeviceLocalResourceReadScope?
        f.backend.onRead = {
            self.assertGateError { _=try active!.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[]) }
            self.assertGateError { _=try f.grants.verify(f.receipt) }
            self.assertGateError { try f.packages.initializeExplicit() }
            throw Marker.injected
        }
        XCTAssertThrowsError(try f.gate.withReadScope { scope in active=scope;_=try scope.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[]) }) { XCTAssertTrue($0 is Marker) }
        f.backend.onRead=nil
        for path in f.locks { try assertReleased(path) }
        XCTAssertNoThrow(try f.grants.verify(f.receipt));assertGateError { _=try active!.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[]) }
    }
    func testOrdinaryBackendAndFaultNestedCrossStoreOrGateRejectGlobally()throws {
        let f=try fixture();var checked=false
        f.backend.onRead = {
            self.assertGateError { try f.packages.initializeExplicit() }
            self.assertGateError { _=try f.gate.withReadScope {_ in 1} };checked=true
        }
        XCTAssertNoThrow(try f.grants.verify(f.receipt));XCTAssertTrue(checked);f.backend.onRead=nil
        let newRoot=f.root.appendingPathComponent("fault-root");try FileManager.default.createDirectory(at:newRoot,withIntermediateDirectories:false)
        var faultCalled=false
        let fault=DeviceStructuralStore(root:newRoot,rootID:id(90)) { _ in
            faultCalled=true
            self.assertGateError { try f.grants.initializeExplicit() }
            self.assertGateError { _=try f.gate.withReadScope {_ in 1} }
            throw Marker.injected
        }
        XCTAssertThrowsError(try fault.initializeExplicit()) { XCTAssertEqual($0 as? DeviceStructuralStoreError,.outcomeUncertain) };XCTAssertTrue(faultCalled)
        XCTAssertNoThrow(try f.grants.verify(f.receipt))
    }
    func testEscapedAndCrossThreadScopesFailWithoutWaitingForHeldLocks()throws {
        let f=try fixture();var escaped:DeviceLocalResourceReadScope?
        try f.gate.withReadScope { scope in
            escaped=scope;let finished=DispatchSemaphore(value:0),result=Box<Bool>(false)
            DispatchQueue.global().async {
                do { _=try scope.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[]) }
                catch { result.value=error is DeviceLocalResourceGateFailure };finished.signal()
            }
            XCTAssertEqual(finished.wait(timeout:.now()+3),.success);XCTAssertTrue(result.value)
        }
        assertGateError { _=try escaped!.diagnoseStructural(operationID:id(999)) }
        XCTAssertThrowsError(try f.gate.withReadScope {_ in throw Marker.injected}) { XCTAssertTrue($0 is Marker) }
        XCTAssertNoThrow(try f.grants.initializeExplicit())
    }
    func testMissingRootBindingLockOrOperationsNeverCreated()throws {
        for missing in ["root","root-binding.json","preparation.lock","operations"] {
            let f=try fixture(),root=f.root.appendingPathComponent("z-packages")
            if missing == "root" { try FileManager.default.removeItem(at:root) }
            else { try FileManager.default.removeItem(at:root.appendingPathComponent(missing)) }
            XCTAssertThrowsError(try f.gate.withReadScope {_ in XCTFail("Incomplete roots must reject")})
            XCTAssertFalse(FileManager.default.fileExists(atPath:missing == "root" ? root.path:root.appendingPathComponent(missing).path))
            for path in f.locks where FileManager.default.fileExists(atPath:path.path) { try assertReleased(path) }
        }
    }
    func testRootSeparatorAndExactUTF8OverlapRules() {
        XCTAssertTrue(DeviceLocalResourceDescriptor.pathsOverlap("/","/owned"))
        XCTAssertTrue(DeviceLocalResourceDescriptor.pathsOverlap("/owned","/"))
        XCTAssertTrue(DeviceLocalResourceDescriptor.pathsOverlap("/owned","/owned/child"))
        XCTAssertTrue(DeviceLocalResourceDescriptor.pathsOverlap("/owned","/owned"))
        XCTAssertFalse(DeviceLocalResourceDescriptor.pathsOverlap("/owned","/owned-other"))
        XCTAssertFalse(DeviceLocalResourceDescriptor.pathsOverlap("/é","/e\u{301}/child"))
    }
    func testDuplicateAndAncestorRootsRejectedWithoutSetup()throws {
        let f=try fixture()
        let alias=DeviceStructuralStore(root:f.root.appendingPathComponent("z-packages"),rootID:id(99))
        XCTAssertEqual(try f.packages.resourceGateDescriptor.path,try alias.resourceGateDescriptor.path)
        let gate=DeviceLocalResourceGate(packageStore:f.packages,grantStore:f.grants,structuralStore:alias)
        assertGateError { _=try gate.withReadScope {_ in 1} }
        let ancestor=DeviceStructuralStore(root:f.root,rootID:id(98))
        assertGateError { _=try DeviceLocalResourceGate(packageStore:f.packages,grantStore:f.grants,structuralStore:ancestor).withReadScope {_ in 1} }
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("structural.lock").path))
    }
    func testGateDoesNotRenewUncertainGrantReceipt()throws {
        let f=try fixture();var armed=false
        let other=DeviceGrantPreparationStore(root:f.root.appendingPathComponent("a-grants"),rootID:id(2),protectedScope:f.scope,backend:f.backend) { if armed && $0 == .afterDirectorySync(.confirmation) { throw Marker.injected } }
        try other.initializeExplicit();armed=true;XCTAssertThrowsError(try other.recommitExact(f.request))
        try f.gate.withReadScope { scope in XCTAssertThrowsError(try scope.verifyGrants(f.receipt,exactRequest:f.request,expectedEntries:[])) }
        XCTAssertThrowsError(try f.grants.verify(f.receipt))
        armed=false;_=try f.grants.recommitExact(f.request)
    }
    func testAnotherInstanceOrdinaryMutationCompletesOnlyAfterGateRelease()throws {
        let f=try fixture(),other=DeviceStructuralStore(root:f.root.appendingPathComponent("m-structural"),rootID:id(3))
        let started=DispatchSemaphore(value:0),finished=DispatchSemaphore(value:0),failed=Box<Bool>(false)
        try f.gate.withReadScope { _ in
            DispatchQueue.global().async {
                started.signal();do { try other.initializeExplicit() } catch { failed.value=true };finished.signal()
            }
            XCTAssertEqual(started.wait(timeout:.now()+3),.success)
            try assertBusy(f.locks[1]) // Deterministic underlying exclusion, not elapsed sleeping.
            XCTAssertEqual(finished.wait(timeout:.now()),.timedOut)
        }
        XCTAssertEqual(finished.wait(timeout:.now()+3),.success);XCTAssertFalse(failed.value)
    }
    func testIndependentProcessNonblockingFlockProbe()throws {
        guard FileManager.default.isExecutableFile(atPath:"/usr/bin/python3") else { throw XCTSkip("Bounded independent-process lock probe requires system Python") }
        let f=try fixture()
        try f.gate.withReadScope { _ in
            let process=Process(),output=Pipe(),finished=DispatchSemaphore(value:0)
            process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
            process.arguments=["-c","import sys,fcntl,os\nfor path in sys.argv[1:]:\n fd=os.open(path,os.O_RDWR)\n try:\n  fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)\n  print('UNEXPECTED')\n except BlockingIOError: print('BUSY')\n finally: os.close(fd)"]+f.locks.map(\.path)
            process.standardOutput=output;process.standardError=output;process.terminationHandler={_ in finished.signal()}
            try process.run()
            if finished.wait(timeout:.now()+5) != .success {
                process.terminate();if finished.wait(timeout:.now()+1) != .success { _=kill(process.processIdentifier,SIGKILL);_=finished.wait(timeout:.now()+1) }
                XCTFail("Owned nonblocking probe exceeded deadline");return
            }
            XCTAssertEqual(process.terminationStatus,0)
            let bytes=output.fileHandleForReading.readDataToEndOfFile();XCTAssertLessThan(bytes.count,1024)
            XCTAssertEqual(String(decoding:bytes,as:UTF8.self),"BUSY\nBUSY\nBUSY\n")
        }
    }
    func testStructuralScopedDiagnosisStaysDiagnostic()throws {
        let f=try fixture(),snapshot=DeviceStructuralSnapshot(generationID:id(21),entries:[],configuredEntryID:nil,contentOwner:nil,grantSet:nil)
        let envelope=DeviceStructuralCommitEnvelope(operationID:id(22),expectedGenerationID:nil,snapshot:snapshot,intent:Data(),outcome:Data())
        let bytes=try StructuralStoreCodec.encode(envelope)
        let record=DeviceStructuralOperationRecord(rootID:id(3),operationID:id(22),expectedOld:nil,candidate:bytes,resourceAssertions:Data())
        try f.structural.prepare(record)
        try f.gate.withReadScope { scope in
            guard case .oldObserved(let observed)=try scope.diagnoseStructural(operationID:id(22)) else { return XCTFail("Must remain unresolved diagnostic") }
            XCTAssertEqual(observed.operationID,id(22));self.assertGateError { _=try f.structural.attempt(operationID:self.id(22)) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath:f.root.appendingPathComponent("m-structural/structural-envelope.json").path))
    }
    #if canImport(CryptoKit)
    func testGenuinePackageReceiptExplicitScopedVerification()throws {
        let f=try fixture(),file=Data("<html></html>".utf8)
        func hash(_ data:Data)->String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
        func encode<T:Encodable>(_ value:T)throws->Data { let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try encoder.encode(value) }
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:id(30).uuidString.lowercased(),name:"Fixture",revision:id(31).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[],files:[.init(path:"index.html",bytes:file.count,sha256:hash(file))])
        manifest.digest=hash(try encode(manifest))
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        let package=try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:file)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
        let receipt=try f.packages.prepareExact(.init(operationID:id(32),package:package))
        try f.gate.withReadScope { scope in
            XCTAssertEqual(try scope.verifyPackage(receipt).package,package)
            self.assertGateError { _=try f.packages.verify(receipt) }
        }
        XCTAssertEqual(try f.packages.verify(receipt).package,package)
    }
    #endif

}
