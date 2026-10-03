import XCTest
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@_spi(DeviceGrantTransport) @testable import ScreenpunkCore

final class DeviceGrantCredentialTransportTests: XCTestCase {
    private enum Marker: Error { case visitor }
    /// Sequential injected fixture only, no platform storage or concurrent mutation.
    private final class Transport: DeviceGrantCredentialTransport, @unchecked Sendable {
        var rootID = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
        var values: [String:DeviceGrantCredentialTransportSecret] = [:]
        var observations: [DeviceGrantCredentialObservation]?
        var calls = 0
        var readHook: (() -> Void)?
        func inventory(maximum: Int, visit: (DeviceGrantCredentialObservation) throws -> Void) throws {
            calls += 1
            for observation in observations ?? values.values.map(\.observation).sorted(by:{$0.account < $1.account}) { try visit(observation) }
        }
        func read(account: String, maximumBytes: Int) throws -> DeviceGrantCredentialTransportSecret? { calls += 1; readHook?(); return values[account] }
        func add(account: String, bytes: Data) throws -> DeviceGrantCredentialObservation {
            calls += 1; guard values[account] == nil else { throw DeviceGrantCredentialTransportFailure.duplicateItem }
            let observation = try DeviceGrantCredentialObservation(account:account,persistentReference:Data("opaque-\(calls)".utf8),byteCount:bytes.count)
            values[account] = try .init(observation:observation,bytes:bytes); return observation
        }
    }
    private func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))! }
    private func account(_ n: Int = 2, kind: DeviceGrantCredentialAccount.Kind = .credential) -> String { DeviceGrantCredentialAccount(kind:kind,id:id(n)).name }
    private func backend(_ transport: Transport) throws -> DeviceGrantCredentialTransportBackend { try .init(rootID:id(1),transport:transport) }
    private var service: String { DeviceGrantCredentialNamespace(rootID:id(1)).service }
    func testExactNamespaceAccountsAndExistingInternalBackendConversion() throws {
        let transport = Transport(), backend: any DeviceGrantCredentialBackend = try backend(transport), secret = Data("PRIVATE_TRANSPORT_CANARY_31".utf8)
        let item = try backend.add(service:service,account:account(),bytes:secret)
        let value = try XCTUnwrap(backend.read(service:service,account:account(),maximumBytes:8192))
        XCTAssertEqual(value.item,item); XCTAssertEqual(value.bytes,secret)
        var observed: [DeviceGrantCredentialItem] = []
        try backend.inventory(service:service,maximum:1) { observed.append($0) }; XCTAssertEqual(observed,[item])
        let calls = transport.calls
        for supplied in ["xyz.screenpunk.connections","xyz.screenpunk.installation.cloud","xyz.screenpunk.installation.cloud.enrollment-stage.v1",service+"\0"] {
            XCTAssertThrowsError(try backend.read(service:supplied,account:account(),maximumBytes:8192))
        }
        for supplied in [account().uppercased(),account()+"\0","credential."+id(2).uuidString.lowercased()+"x","attempt.not-a-uuid"] {
            XCTAssertThrowsError(try backend.add(service:service,account:supplied,bytes:secret))
        }
        XCTAssertEqual(transport.calls,calls)
    }
    func testPrivateTransportHasNoSecretReflectionOrEncodingSurface() throws {
        let bytes = Data("TRANSPORT_SECRET_EXCLUSION_CANARY".utf8), observation = try DeviceGrantCredentialObservation(account:account(),persistentReference:Data("safe-reference".utf8),byteCount:bytes.count)
        let payload = try DeviceGrantCredentialTransportSecret(observation:observation,bytes:bytes)
        XCTAssertEqual(Mirror(reflecting:payload).children.count,0)
        for text in [String(describing:payload),String(reflecting:payload)] { XCTAssertFalse(text.contains(String(decoding:bytes,as:UTF8.self))); XCTAssertFalse(text.contains(bytes.base64EncodedString())) }
        XCTAssertThrowsError(try DeviceGrantCredentialTransportSecret(observation:observation,bytes:Data()))
        // Coincidence is not a token-content policy; public identifiers may share short token bytes.
        XCTAssertNoThrow(try DeviceGrantCredentialTransportSecret(observation:.init(account:account(),persistentReference:Data("a".utf8),byteCount:1),bytes:Data("a".utf8)))
    }
    func testLimitsRejectBeforeTransportEffectsAndBoundObservations() throws {
        let transport = Transport(), backend = try backend(transport)
        XCTAssertThrowsError(try backend.add(service:service,account:account(),bytes:Data(repeating:1,count:8193)))
        XCTAssertThrowsError(try backend.add(service:service,account:account(kind:.attempt),bytes:Data(repeating:1,count:4*1024*1024+1)))
        XCTAssertThrowsError(try backend.add(service:service,account:account(),bytes:Data()))
        XCTAssertThrowsError(try backend.inventory(service:service,maximum:4226) {_ in})
        XCTAssertThrowsError(try backend.read(service:service,account:account(),maximumBytes:8193))
        XCTAssertEqual(transport.calls,0)
        XCTAssertNoThrow(try DeviceGrantCredentialObservation(account:account(),persistentReference:Data([1]),byteCount:8192))
        XCTAssertNoThrow(try DeviceGrantCredentialObservation(account:account(kind:.attempt),persistentReference:Data([1]),byteCount:4*1024*1024))
        XCTAssertThrowsError(try DeviceGrantCredentialObservation(account:account(),persistentReference:Data(),byteCount:1))
        XCTAssertThrowsError(try DeviceGrantCredentialObservation(account:account(),persistentReference:Data(repeating:1,count:4097),byteCount:1))
    }
    func testBoundedVisitsDuplicatesReentryAndVisitorFailure() throws {
        let transport = Transport(), backend = try backend(transport)
        let first = try backend.add(service:service,account:account(),bytes:Data([7]))
        let second = try backend.add(service:service,account:account(3),bytes:Data([8]))
        try backend.inventory(service:service,maximum:2) { item in
            XCTAssertEqual(try backend.read(service:self.service,account:item.account,maximumBytes:8192)?.item,item)
        }
        XCTAssertThrowsError(try backend.inventory(service:service,maximum:2) {_ in throw Marker.visitor}) { XCTAssertTrue($0 is Marker) }
        transport.observations = [try .init(account:first.account,persistentReference:first.persistentReference,byteCount:first.byteCount),try .init(account:second.account,persistentReference:second.persistentReference,byteCount:second.byteCount)]
        XCTAssertThrowsError(try backend.inventory(service:service,maximum:1) {_ in})
        transport.observations = [transport.observations![0],transport.observations![0]]
        XCTAssertThrowsError(try backend.inventory(service:service,maximum:2) {_ in})
    }
    func testWrongReadIdentityAndChangingRootFailClosed() throws {
        let transport = Transport(), backend = try backend(transport)
        let observation = try DeviceGrantCredentialObservation(account:account(3),persistentReference:Data([1]),byteCount:3)
        transport.values[account()] = try .init(observation:observation,bytes:Data([1,2,3]))
        XCTAssertThrowsError(try backend.read(service:service,account:account(),maximumBytes:8192))
        transport.readHook = { transport.rootID = self.id(4) }
        XCTAssertThrowsError(try backend.read(service:service,account:account(),maximumBytes:8192))
        XCTAssertThrowsError(try DeviceGrantCredentialTransportBackend(rootID:id(1),transport:transport))
    }
    func testTransportAdapterIsAcceptedByUnmountedPreparationStore() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil)); defer { free(physical) }
        let root = URL(fileURLWithPath:String(cString:physical),isDirectory:true).appendingPathComponent("grant-transport-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false); defer { try? FileManager.default.removeItem(at:root) }
        let sibling = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected")
        let scope = DevicePackageProtectedScope(legacyStateRoot:sibling.appendingPathComponent("state"),legacyArchiveRoot:sibling.appendingPathComponent("archive"),resetRoot:sibling.appendingPathComponent("reset"),cloudRoot:sibling.appendingPathComponent("cloud"),managementRoot:sibling.appendingPathComponent("management"),preferencesRoot:sibling.appendingPathComponent("preferences"),otherProtectedRoots:[])
        let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(1),revisionID:id(5)),owner:.init(role:.controller,publicKey:[UInt8](repeating:7,count:32)),entries:[],credentials:[],retainedRevisions:[])
        let request = DeviceGrantPreparationRequest(operationID:id(6),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
        let transport = Transport(), store = DeviceGrantPreparationStore(root:root,rootID:id(1),protectedScope:scope,backend:try backend(transport))
        try store.initializeExplicit(); let receipt = try store.prepareExact(request)
        XCTAssertEqual(try store.verify(receipt).identity,input.identity)
        XCTAssertEqual(transport.values.count,1)
    }
    func testCompleteInventoryRejectsSharedPersistentReference() throws {
        let transport = Transport(), backend = try backend(transport)
        transport.observations = [try .init(account:account(),persistentReference:Data([1]),byteCount:1),try .init(account:account(3),persistentReference:Data([1]),byteCount:1)]
        XCTAssertThrowsError(try backend.inventory(service:service,maximum:2) {_ in})
        transport.observations = [try .init(account:account(),persistentReference:Data([1]),byteCount:1),try .init(account:account(3),persistentReference:Data([2]),byteCount:1)]
        var count = 0; try backend.inventory(service:service,maximum:2) {_ in count += 1}; XCTAssertEqual(count,2)
    }

}
