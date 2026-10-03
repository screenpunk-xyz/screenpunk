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

final class DeviceGrantPreparationTests: XCTestCase {
    private final class Backend: DeviceGrantCredentialBackend, @unchecked Sendable {
        var values: [String:DeviceGrantCredentialValue] = [:]
        var adds = 0
        func inventory(service: String, maximum: Int, visit: (DeviceGrantCredentialItem) throws -> Void) throws {
            for key in values.keys.sorted() { try visit(values[key]!.item) }
        }
        func read(service: String, account: String, maximumBytes: Int) throws -> DeviceGrantCredentialValue? {
            guard let value = values[account] else { return nil }
            guard value.bytes.count <= maximumBytes else { throw DeviceGrantPreparationError.sizeLimit }; return value
        }
        func add(service: String, account: String, bytes: Data) throws -> DeviceGrantCredentialItem {
            guard values[account] == nil else { throw DeviceGrantPreparationError.conflict }; adds += 1
            let item = DeviceGrantCredentialItem(account:account,persistentReference:Data(UUID().uuidString.utf8),byteCount:bytes.count)
            values[account] = .init(item:item,bytes:bytes); return item
        }
    }
    private func id(_ n: Int) -> UUID { UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))! }
    private func root() throws -> URL {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path,nil))
        defer { free(physical) }
        let root = URL(fileURLWithPath:String(cString:physical),isDirectory:true)
            .appendingPathComponent("grant-preparation-tests-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
        addTeardownBlock { try? FileManager.default.removeItem(at:root) }; return root
    }
    private func scope(_ root: URL) -> DevicePackageProtectedScope {
        let sibling = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-protected")
        return .init(legacyStateRoot:sibling.appendingPathComponent("state"),legacyArchiveRoot:sibling.appendingPathComponent("archive"),resetRoot:sibling.appendingPathComponent("reset"),cloudRoot:sibling.appendingPathComponent("cloud"),managementRoot:sibling.appendingPathComponent("management"),preferencesRoot:sibling.appendingPathComponent("preferences"),otherProtectedRoots:[])
    }
    private func store(_ root: URL, _ backend: Backend, boundary: @escaping (DeviceGrantPreparationStore.Boundary) throws -> Void = {_ in}) -> DeviceGrantPreparationStore {
        .init(root:root,rootID:id(1),protectedScope:scope(root),backend:backend,boundary:boundary)
    }
    private func request(_ n: Int = 10) throws -> DeviceGrantPreparationRequest {
        let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(1),revisionID:id(n+1000)),owner:.init(role:.controller,publicKey:[UInt8](repeating:7,count:32)),entries:[],credentials:[],retainedRevisions:[])
        return .init(operationID:id(n),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:[]),expectedEntries:[])
    }
    private func operation(_ root: URL, _ request: DeviceGrantPreparationRequest, _ suffix: String) -> URL { root.appendingPathComponent("operations/"+request.operationID.uuidString.lowercased()+suffix) }
    private func replaceSameBytes(_ path: URL) throws {
        let bytes = try Data(contentsOf:path), temp = path.appendingPathExtension("external")
        try bytes.write(to:temp); try FileManager.default.removeItem(at:path); try FileManager.default.moveItem(at:temp,to:path)
    }
    func testExplicitInitializationNoImplicitRootAndSecretFreeJournal() throws {
        let root = try root(), backend = Backend(), request = try request(), store = store(root,backend)
        XCTAssertThrowsError(try store.prepareExact(request)); XCTAssertEqual(backend.adds,0)
        try store.initializeExplicit(); let receipt = try store.prepareExact(request)
        XCTAssertEqual(try store.verify(receipt).identity,request.input.identity)
        XCTAssertEqual(backend.adds,1)
        for path in try FileManager.default.subpathsOfDirectory(atPath:root.path) where path != "operations" {
            let file = root.appendingPathComponent(path)
            let text = String(decoding:try Data(contentsOf:file),as:UTF8.self)
            XCTAssertFalse(text.contains("publicKey")); XCTAssertFalse(text.contains("privateCanonical"))
        }
        XCTAssertEqual(Mirror(reflecting:receipt).children.count,0)
        XCTAssertFalse(String(reflecting:receipt).contains(request.input.owner.publicKey.map(String.init).joined()))
    }
    func testRestartRequiresExactLatestRecommitOldReplayCannotQualifyTip() throws {
        let root = try root(), backend = Backend(), first = try request(), second = try request(11)
        let a = store(root,backend); try a.initializeExplicit(); _ = try a.prepareExact(first); _ = try a.prepareExact(second)
        let b = store(root,backend); try b.initializeExplicit()
        XCTAssertThrowsError(try b.prepareExact(try request(12)))
        _ = try b.recommitExact(first)
        XCTAssertThrowsError(try b.prepareExact(try request(12)))
        let receipt = try b.recommitExact(second); XCTAssertNoThrow(try b.verify(receipt))
        _ = try b.prepareExact(try request(12)); XCTAssertEqual(backend.adds,3)
    }
    func testHeadDeleteAndSameBytesReplacementBlockAfterRestart() throws {
        for deletion in [false,true] {
            let root = try root(), backend = Backend(), request = try request(), a = store(root,backend)
            try a.initializeExplicit(); _ = try a.prepareExact(request)
            let head = root.appendingPathComponent("head.json")
            if deletion { try FileManager.default.removeItem(at:head) } else { try replaceSameBytes(head) }
            let b = store(root,backend)
            XCTAssertThrowsError(try b.initializeExplicit()); XCTAssertThrowsError(try a.recommitExact(request))
        }
    }
    func testTerminalIdentityReplacementAndMissingChainBlock() throws {
        for deletion in [false,true] {
            let root = try root(), backend = Backend(), request = try request(), a = store(root,backend)
            try a.initializeExplicit(); _ = try a.prepareExact(request)
            let terminal = operation(root,request,".terminal")
            if deletion { try FileManager.default.removeItem(at:terminal) } else { try replaceSameBytes(terminal) }
            XCTAssertThrowsError(try a.recommitExact(request)); XCTAssertThrowsError(try store(root,backend).initializeExplicit())
        }
    }
    func testUncertainHeadAndConfirmationRequireExactRepairAcrossInstances() throws {
        for fault in [DeviceGrantPreparationStore.Boundary.afterReplace(.head), .afterReplace(.confirmation)] {
            let root = try root(), backend = Backend(), first = try request(), second = try request(11)
            var armed = false
            let a = store(root,backend); try a.initializeExplicit(); let original = try a.prepareExact(first)
            let b = store(root,backend) { if armed && $0 == fault { throw DeviceGrantPreparationError.io(5) } }
            try b.initializeExplicit(); armed = true
            // Recommit of already confirmed tip synchronizes rather than replaces the head. Fault at
            // confirmation directory sync covers same-tip uncertainty; new attempt covers head rename.
            if fault == .afterReplace(.head) {
                armed = false; _ = try b.recommitExact(first); armed = true
                XCTAssertThrowsError(try b.prepareExact(second))
            } else {
                armed = false; _ = try b.recommitExact(first); armed = true
                XCTAssertThrowsError(try b.prepareExact(second))
            }
            XCTAssertThrowsError(try a.verify(original)); XCTAssertThrowsError(try a.prepareExact(try request(12)))
            let c = store(root,backend); try c.initializeExplicit()
            XCTAssertThrowsError(try c.prepareExact(try request(12)))
            let recovered = try c.recommitExact(second); XCTAssertNoThrow(try c.verify(recovered))
        }
        let root = try root(), backend = Backend(), request = try request()
        let a = store(root,backend); try a.initializeExplicit(); _ = try a.prepareExact(request)
        var armed = false
        let b = store(root,backend) { if armed && $0 == .afterDirectorySync(.confirmation) { throw DeviceGrantPreparationError.io(5) } }
        try b.initializeExplicit(); armed = true; XCTAssertThrowsError(try b.recommitExact(request))
        XCTAssertThrowsError(try a.prepareExact(try self.request(11)))
        armed = false; _ = try b.recommitExact(request); _ = try b.prepareExact(try self.request(11))
    }
    func testPrivateAddOrphanIsNeverAdoptedAfterRestartButLiveIdentityRepairs() throws {
        let root = try root(), backend = Backend(), request = try request(); var armed = true
        let a = store(root,backend) { if armed, case .afterPrivateAdd = $0 { throw DeviceGrantPreparationError.io(5) } }
        try a.initializeExplicit(); XCTAssertThrowsError(try a.prepareExact(request)); XCTAssertEqual(backend.adds,1)
        XCTAssertThrowsError(try store(root,backend).initializeExplicit())
        armed = false; let receipt = try a.recommitExact(request); XCTAssertNoThrow(try a.verify(receipt)); XCTAssertEqual(backend.adds,1)
    }
    func testBoundedFaultMatrixExactRestartRepairOrExplicitOrphanBlock() throws {
        let boundaries: [DeviceGrantPreparationStore.Boundary] = [.afterWrite(.intent),.afterReplace(.intent),.afterWrite(.progress),.afterReplace(.progress),.afterWrite(.terminal),.afterReplace(.terminalBinding),.afterReplace(.terminal),.afterWrite(.head),.afterReplace(.headBinding),.afterReplace(.head),.afterReplace(.confirmation)]
        for target in boundaries {
            let root = try root(), backend = Backend(), request = try request(); var armed = true
            let a = store(root,backend) { if armed && $0 == target { throw DeviceGrantPreparationError.io(5) } }
            try a.initializeExplicit(); XCTAssertThrowsError(try a.prepareExact(request),"\(target)")
            let b = store(root,backend)
            if target == .afterWrite(.terminal) || target == .afterWrite(.head) || target == .afterWrite(.intent) || target == .afterReplace(.intent) {
                // Intent with no durable private identity, and unbound staged inodes, cannot be adopted.
                if (try? b.initializeExplicit()) != nil { XCTAssertThrowsError(try b.recommitExact(request),"\(target)") }
                armed = false; XCTAssertNoThrow(try a.recommitExact(request),"\(target)")
            } else {
                try b.initializeExplicit(); XCTAssertNoThrow(try b.recommitExact(request),"\(target)")
            }
        }
    }
    func testBindingUncertaintyMustBeExplicitlyRecoveredAndScopesAreDisjoint() throws {
        let root = try root(), backend = Backend(); var armed = true
        let a = store(root,backend) { if armed && $0 == .afterReplace(.binding) { throw DeviceGrantPreparationError.io(5) } }
        XCTAssertThrowsError(try a.initializeExplicit())
        let b = store(root,backend); XCTAssertThrowsError(try b.prepareExact(try request()))
        try b.initializeExplicit(); _ = try b.prepareExact(try request())
        armed = false
        let overlap = DevicePackageProtectedScope(legacyStateRoot:root,legacyArchiveRoot:root,resetRoot:root,cloudRoot:root,managementRoot:root,preferencesRoot:root,otherProtectedRoots:[])
        XCTAssertThrowsError(try DeviceGrantPreparationStore(root:root,rootID:id(1),protectedScope:overlap,backend:backend).initializeExplicit())
        XCTAssertEqual(backend.adds,1)
    }
    func testStrictMetadataAndRootResidueFailClosed() throws {
        let root = try root(), backend = Backend(), a = store(root,backend)
        try a.initializeExplicit()
        try Data("{}".utf8).write(to:root.appendingPathComponent("root-binding.json.pending"))
        XCTAssertThrowsError(try a.prepareExact(try request())); XCTAssertEqual(backend.adds,0)
        XCTAssertThrowsError(try GrantPreparationCodec.decodeHead(Data("{\"schemaVersion\":1,\"schemaVersion\":1}".utf8)))
        XCTAssertThrowsError(try GrantPreparationCodec.decodeRecord(Data(repeating:65,count:GrantPreparationCodec.recordLimit+1)))
    }
    func testCapacityRetainsAllHistoryAndRefusesNextBeforePrivateEffects() throws {
        let root = try root(), backend = Backend(), a = store(root,backend); try a.initializeExplicit()
        for n in 10..<138 { _ = try a.prepareExact(try request(n)) }
        let count = backend.adds
        XCTAssertThrowsError(try a.prepareExact(try request(138))) { XCTAssertEqual($0 as? DeviceGrantPreparationError,.capacity) }
        XCTAssertEqual(backend.adds,count)
        _ = try a.recommitExact(try request()); XCTAssertEqual(backend.adds,count)
    }
    #if canImport(CryptoKit)
    private func authenticatedRequest(_ n: Int, secret: Data, credentialID: UUID) throws -> DeviceGrantPreparationRequest {
        func encode<T:Encodable>(_ value: T) throws -> Data { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]; return try e.encode(value) }
        func hash(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
        let html = Data("<html></html>".utf8)
        var manifest = DashboardManifest(schemaVersion:1,dashboardId:id(500).uuidString.lowercased(),name:"Fixture",revision:id(501).uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",
            target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[.init(alias:"api",required:false,operations:[.init(name:"read",kind:"http")])],files:[.init(path:"index.html",bytes:html.count,sha256:hash(html))])
        manifest.digest = hash(try encode(manifest))
        let revision = StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        let package = try DevicePackageQualifier.qualify(.init(manifest:encode(manifest),files:[.init(path:"index.html",bytes:html)]),expected:.init(revision:revision,target:.init(deviceId:"device",name:"Device"),profileID:"profile"))
        let grant = ConnectionGrant(schemaVersion:1,id:id(600),alias:"api",origin:"https://example.com",transport:.http,authRef:"auth",lan:false,allowInsecureHTTP:false,
            operations:[.init(name:"read",kind:.http,method:.GET,path:"/states",idempotent:true,write:false)])
        let config = ConnectionProvisioning(dashboardId:revision.dashboardId,revision:revision.revision,provisioningId:"explicit-approval",entries:[.init(grant:grant,binding:.init(authRef:"auth",placement:.bearer),secret:secret)])
        let entry = DeviceGrantEntryInput(entryID:id(700),revision:revision,generic:config,homeAssistant:nil,publicReads:nil,credentialReferences:[.init(credentialRevisionID:credentialID,kind:.generic,key:"auth")])
        let expected = [DeviceGrantEntryExpectation(entryID:entry.entryID,package:package)]
        let input = DeviceGrantRevisionInput(schemaVersion:1,identity:.init(rootID:id(1),revisionID:id(n+1000)),owner:.init(role:.controller,publicKey:[UInt8](repeating:7,count:32)),entries:[entry],credentials:[.init(revisionID:credentialID,bytes:secret)],retainedRevisions:[])
        return .init(operationID:id(n),input:input,qualified:try DeviceGrantRevisionQualifier.qualify(input,expectedEntries:expected),expectedEntries:expected)
    }
    func testActualSecretProjectionSharingAndConflictsBeforeEffects() throws {
        let root = try root(), backend = Backend(), a = store(root,backend)
        let secret = Data("PREPARATION_PRIVATE_CANARY_27".utf8), credential = id(900)
        let first = try authenticatedRequest(10,secret:secret,credentialID:credential)
        try a.initializeExplicit(); let receipt = try a.prepareExact(first); XCTAssertEqual(backend.adds,2)
        _ = try a.prepareExact(authenticatedRequest(11,secret:secret,credentialID:credential)); XCTAssertEqual(backend.adds,3)
        XCTAssertNoThrow(try a.verify(receipt))
        for path in try FileManager.default.subpathsOfDirectory(atPath:root.path) where path != "operations" {
            let bytes = try Data(contentsOf:root.appendingPathComponent(path)), text = String(decoding:bytes,as:UTF8.self)
            for privateText in [String(decoding:secret,as:UTF8.self),secret.base64EncodedString(),SHA256.hash(data:secret).map { String(format:"%02x",$0) }.joined()] { XCTAssertFalse(text.contains(privateText)) }
            if path.hasSuffix(".json") || path.hasSuffix(".terminal") {
                let object = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
                if let encoded = object["publicMetadata"] as? String, let metadata = Data(base64Encoded:encoded) {
                    let publicObject = try JSONSerialization.jsonObject(with:metadata) as! [String:Any]
                    XCTAssertNil(publicObject["credentials"])
                    let e = (publicObject["entries"] as! [[String:Any]])[0], generic = e["generic"] as! [String:Any]
                    XCTAssertNil((generic["entries"] as! [[String:Any]])[0]["secret"])
                }
            }
        }
        XCTAssertThrowsError(try a.prepareExact(authenticatedRequest(12,secret:Data("different".utf8),credentialID:credential))); XCTAssertEqual(backend.adds,3)
        let bad = DeviceGrantPreparationRequest(operationID:id(13),input:first.input,qualified:try request().qualified,expectedEntries:first.expectedEntries)
        XCTAssertThrowsError(try a.prepareExact(bad)); XCTAssertEqual(backend.adds,3)
    }
    func testPartialCredentialAddRestartOrphanAndPersistentReferenceReplacement() throws {
        let root = try root(), backend = Backend(), secret = Data("PRIVATE_CREDENTIAL".utf8), credential = id(900)
        let request = try authenticatedRequest(10,secret:secret,credentialID:credential); var armed = true
        let a = store(root,backend) { if armed && $0 == .afterPrivateAdd(GrantPreparationCodec.credentialAccount(credential)) { throw DeviceGrantPreparationError.io(5) } }
        try a.initializeExplicit(); XCTAssertThrowsError(try a.prepareExact(request)); XCTAssertEqual(backend.adds,2)
        XCTAssertThrowsError(try store(root,backend).initializeExplicit())
        armed = false; _ = try a.recommitExact(request); XCTAssertEqual(backend.adds,2)
        let account = GrantPreparationCodec.credentialAccount(credential), value = backend.values[account]!
        backend.values[account] = .init(item:.init(account:account,persistentReference:Data("replacement-identity".utf8),byteCount:value.bytes.count),bytes:value.bytes)
        XCTAssertThrowsError(try a.recommitExact(request)); XCTAssertThrowsError(try store(root,backend).initializeExplicit())
    }
    #endif
    func testSymlinksHardlinksAndUnknownResiduePreserveSentinels() throws {
        let root = try root(), backend = Backend(), request = try request(), a = store(root,backend)
        try a.initializeExplicit(); _ = try a.prepareExact(request)
        let sentinel = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent+"-sentinel")
        try Data("sentinel".utf8).write(to:sentinel); addTeardownBlock { try? FileManager.default.removeItem(at:sentinel) }
        let foreign = operation(root,request,".unknown")
        try FileManager.default.createSymbolicLink(at:foreign,withDestinationURL:sentinel)
        XCTAssertThrowsError(try a.recommitExact(request)); XCTAssertEqual(try Data(contentsOf:sentinel),Data("sentinel".utf8))
        try FileManager.default.removeItem(at:foreign)
        let terminal = operation(root,request,".terminal"), linked = root.appendingPathComponent("terminal-hardlink")
        try FileManager.default.linkItem(at:terminal,to:linked)
        XCTAssertThrowsError(try a.recommitExact(request)); XCTAssertEqual(backend.adds,1)
    }

}
