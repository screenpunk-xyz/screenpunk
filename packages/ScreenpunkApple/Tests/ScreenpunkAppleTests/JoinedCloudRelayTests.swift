import XCTest
@_spi(NativeInstallation) @_spi(DeviceGrantTransport) @testable import ScreenpunkCore
@_spi(NativeInstallation) @testable import ScreenpunkApple
#if canImport(Network) && canImport(Security)
final class JoinedCloudRelayTests: XCTestCase {
    func testActualCloudApprovalAndPairedArchiveRelay() async throws {
        func phase(_ value:String) { FileHandle.standardError.write(Data(("Joined relay phase: " + value + "\n").utf8)) }
        guard let path = ProcessInfo.processInfo.environment["SCREENPUNK_JOINED_CLOUD_FIXTURE"] else {
            throw XCTSkip("Requires the explicitly owned cloud HTTP fixture")
        }
        let values = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String:Any])
        func string(_ key: String) throws -> String { try XCTUnwrap(values[key] as? String) }
        let origin = try XCTUnwrap(URL(string: string("logicalBaseURL")))
        let transport = try XCTUnwrap(URL(string: string("transportBaseURL")))
        JoinedCloudHTTPForwarder.install(logical: origin, transport: transport)
        defer { JoinedCloudHTTPForwarder.remove() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [JoinedCloudHTTPForwarder.self]
        let parent = testPhysicalTemporaryDirectory().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let anchor = parent.appendingPathComponent("Application Support")
        try FileManager.default.createDirectory(at: anchor, withIntermediateDirectories: true)
        let authority = DeviceManagementAuthority(journal: AuthorityJournal(), credentials: .init(backend: AuthorityBackend(), random: { Data() }),
            reset: ManagementTestResetEvidence(), managedNamespace: try .fixture(existingPhysicalAnchor: anchor),
            supportAnchorSetup: try .fixture(existingPhysicalParent: parent), commandIntents: .init(root: parent.appendingPathComponent("intents")), concurrentControlQualified: true)
        try authority.prepareProductionSupportAnchor(); try authority.enterCloudForeground()
        let claim = try NativeClaimInput(requestId: UUID(), transitionId: UUID(), accountId: XCTUnwrap(UUID(uuidString: string("accountId"))),
            locationId: nil, name: "Actual joined native", profile: "tablet")
        let binding = try DeviceManagementFormatHistory.Binding(credentialGenerationID: UUID(), transitionID: claim.transitionId,
            credentialReference: "native." + UUID().uuidString, format: .nativeInstallationV1)
        let proposal = try NativeFirstEnrollmentPreparation(preparationId: UUID(), enrollmentId: UUID(), stageReference: "stage." + UUID().uuidString,
            binding: binding, claimInput: claim)
        let roots = try authority.prepareFreshCloudEnrollmentRoots(claim: claim)
        let protected = NativeManagedProtectedRoots(legacyState: parent.appendingPathComponent("local"), legacyArchive: parent.appendingPathComponent("archive"),
            reset: parent.appendingPathComponent("reset"), cloudEnrollment: roots.journalRoot, management: parent.appendingPathComponent("management"), preferences: parent.appendingPathComponent("preferences"))
        let stores = try NativeFirstManagedStores(namespace: roots.namespace, ids: roots.localIDs, protectedRoots: protected,
            grantTransport: FreshGrantTransport(rootID: roots.localIDs.grant))
        let original48 = Data((0..<48).map { _ in UInt8.random(in: 0...255) })
        let enrollment = try authority.makeFirstEnrollmentSession(roots: roots, proposal: proposal, excludedLocalResetRoot: protected.reset, storage: FreshCredentialStorage(original48:original48))
        let result = try await enrollment.enroll(origin: origin, tokenProvider: JoinedTokens(token: string("humanIdToken")),
            activationRequestID: UUID(), associationAttemptID: UUID(), stores: stores, configuration: configuration)
        phase("enrolled")
        let context = try authority.bindOperationalInstallation(installation: result.installation, activation: result.activation, origin: origin)
        let status = try authority.prepareCloudStatusRequest(context)
        try authority.beginCloudStatusRequest(context, requestID: status.requestID)
        try authority.acceptCloudStatus(await status.performFixedTransport(origin: origin, configuration: configuration), context: context)
        var current = try authority.prepareCurrentInstallationDispatch(context)
        func refreshStatus() async throws {
            let request = try authority.prepareCloudStatusRequest(context)
            try authority.beginCloudStatusRequest(context,requestID:request.requestID)
            try authority.acceptCloudStatus(await request.performFixedTransport(origin:origin,configuration:configuration),context:context)
            current = try authority.prepareCurrentInstallationDispatch(context)
        }
        let execution = try result.installation.makeDeliveryExecutionSession(current: current)
        try await refreshStatus()
        let genesis = try execution.freshGenesisObservation(current: current)
        try await NativeDeliveryStateHTTPObservation.collect(body: genesis, installation: result.installation, current: current,
            origin: origin, configuration: configuration).requireOriginal(body: genesis, installation: result.installation)
        phase("genuine genesis acknowledged")
        let common = try authority.makeUnifiedInventorySession(context: context, current: current, commonRootID: UUID(), native: execution)
        try common.migrate(current: current, operationID: UUID(), generationID: UUID(), admissionEnabled: authority.qualifiedConcurrentControl(context: context))
        try await refreshStatus()
        try await result.installation.makeConcurrentControlCapabilityRequest(origin: origin, current: current, qualified: true).performFixedTransport(configuration:configuration)
        try await refreshStatus()
        let genesisState = try XCTUnwrap(JSONSerialization.jsonObject(with:genesis.bytes) as? [String:Any])
        let genesisGeneration = try XCTUnwrap(UUID(uuidString:XCTUnwrap(genesisState["generationId"] as? String)))
        try common.retainCloudCheckpoint(authenticatedGenerationID: genesisGeneration)
        let observation = try XCTUnwrap(common.pendingCloudObservation())
        try await result.installation.makeUnifiedCloudObservationRequest(origin: origin, current: current, observation: observation).performFixedTransport(configuration:configuration)
        phase("common inventory acknowledged")
        let base = try string("controllerBasePath"), operation = UUID().uuidString.lowercased()
        // Allow the fixture owner to refresh the same account's public-client
        // grant during native setup, without retargeting this enrolled device.
        let controllerValues = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path))) as? [String:Any])
        guard controllerValues["accountId"] as? String == values["accountId"] as? String,
              controllerValues["transportBaseURL"] as? String == values["transportBaseURL"] as? String,
              controllerValues["controllerBasePath"] as? String == base else { throw JoinedFailure.controllerAdmission }
        var token = try XCTUnwrap(controllerValues["controllerToken"] as? String)
        if let refresh = controllerValues["controllerRefreshToken"] as? String, let resource = controllerValues["controllerResource"] as? String {
            var refreshRequest = URLRequest(url:transport.appendingPathComponent("issuer/token"))
            refreshRequest.httpMethod = "POST"
            refreshRequest.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name:"grant_type",value:"refresh_token"),URLQueryItem(name:"client_id",value:"screenpunk-cli"),
                URLQueryItem(name:"refresh_token",value:refresh),URLQueryItem(name:"resource",value:resource)]
            refreshRequest.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            let (bytes,response) = try await URLSession.shared.data(for:refreshRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with:bytes) as? [String:Any], let access = result["access_token"] as? String else {
                throw JoinedFailure.controllerAdmission
            }
            token = access
        }
        func request(_ path: String, body: [String:Any]? = nil) async throws -> [String:Any] {
            var request = URLRequest(url: transport.appendingPathComponent(String(path.dropFirst())))
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            let (bytes,response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                phase("controller admission rejected HTTP " + String((response as? HTTPURLResponse)?.statusCode ?? 0))
                throw JoinedFailure.controllerAdmission
            }
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        }
        let review = try await request(base + "/deployments/review", body: ["publicationId": string("publicationId"), "installationId": result.activation.installationId.uuidString.lowercased(), "operationId":operation,"removeEntryIds":[]])
        _ = try await request(base + "/deployments/apply", body: review)
        let exported = try await request(base + "/projects/" + string("projectId") + "/deployments/" + operation + "/packages/" + string("packageId") + "/archive")
        let archive = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(exported["dataBase64"] as? String)))
        if let directory = ProcessInfo.processInfo.environment["SCREENPUNK_CONTROLLER_HTTP_FIXTURE_DIR"] {
            let folder = URL(fileURLWithPath:directory,isDirectory:true)
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let file = folder.appendingPathComponent("approved-archive.json")
            try JSONSerialization.data(withJSONObject:exported,options:[.sortedKeys]).write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        phase("review applied and approved archive exported")
        try await refreshStatus()
        let command = try await NativeDeliveryCommandHTTPObservation.collect(installation: result.installation, current: current, origin: origin, configuration: configuration)
        let plan = try await command.fetchPlan(current: current, origin: origin, nativeOperationID: UUID(), configuration: configuration)
        try plan.acceptUnified(session: common, current: current)
        phase("fixed cloud plan accepted")
        let localContext = try authority.makeConcurrentLocalContext(context: context, session: common)
        let device = try TLSIdentity.make(role:.device,commonName:"actual-relay-device"), controller = try TLSIdentity.make(role:.controller,commonName:"actual-relay-controller")
        let profile = DeviceProfile(deviceId:"actual-relay",name:"Actual relay",orientation:.landscape,width:1024,height:768)
        let server = try DeviceLANServer(management: localContext, runtime: .init(identity:device.pairingIdentity,profile:profile,
            advertisement:.init(deviceId:profile.deviceId,host:"127.0.0.1",port:0,source:.advertised)), identity:device,homeAssistantVault:.init(store:MemoryCredentialStore()))
        server.onCloudArchiveAdmission = { installation, op, package, digest, count in
            XCTAssertEqual(installation,result.activation.installationId); XCTAssertEqual(op.uuidString.lowercased(),operation)
            try plan.requireRelayedArchive(current:current,packageID:package,digest:digest,byteCount:count)
        }
        server.onCloudArchiveReceived = { _,_,package,bytes in try plan.retainRelayedArchive(current:current,packageID:package,bytes:bytes) }
        try server.attachUnifiedLocalSession(common); try server.start(); defer { server.stop() }
        let client = ControllerLANClient(identity:controller); defer { client.cancel() }
        try client.connect(host:"127.0.0.1",port:server.port,pinnedDevice:device.pin)
        XCTAssertTrue(try client.hello().capabilities?.contains("cloud-archive-relay-v1") == true)
        let pairing = try client.beginPairing(nonce:PairingIdentityFactory.nonce()); try server.confirmLocally(); try client.confirmPairing(code:pairing.code)
        phase("actual TLS controller approved")
        try await refreshStatus()
        let transfer = UUID().uuidString.lowercased()
        let rejected = try LANCloudArchiveChunk(transferId:UUID().uuidString.lowercased(),installationId:result.activation.installationId.uuidString.lowercased(),operationId:operation,
            packageId:string("packageId"),archiveSha256:String(repeating:"0",count:64),archiveBytes:archive.count,offset:0,dataBase64:archive.base64EncodedString(),final:true)
        XCTAssertThrowsError(try client.relayCloudArchiveChunk(rejected))
        let split = archive.count / 2
        let firstChunk = try LANCloudArchiveChunk(transferId:transfer,installationId:result.activation.installationId.uuidString.lowercased(),operationId:operation,
            packageId:string("packageId"),archiveSha256:XCTUnwrap(exported["archiveSha256"] as? String),archiveBytes:archive.count,offset:0,dataBase64:archive.prefix(split).base64EncodedString(),final:false)
        let firstReceipt = try client.relayCloudArchiveChunk(firstChunk)
        XCTAssertFalse(firstReceipt.complete); XCTAssertEqual(firstReceipt.receivedBytes,split)
        XCTAssertEqual(try client.relayCloudArchiveChunk(firstChunk).receivedBytes,split)
        let chunk = try LANCloudArchiveChunk(transferId:transfer,installationId:result.activation.installationId.uuidString.lowercased(),operationId:operation,
            packageId:string("packageId"),archiveSha256:XCTUnwrap(exported["archiveSha256"] as? String),archiveBytes:archive.count,offset:split,dataBase64:archive.dropFirst(split).base64EncodedString(),final:true)
        let receipt = try client.relayCloudArchiveChunk(chunk)
        XCTAssertTrue(receipt.complete); XCTAssertEqual(receipt.receivedBytes,archive.count)
        let retriedReceipt = try client.relayCloudArchiveChunk(chunk)
        XCTAssertTrue(retriedReceipt.complete); XCTAssertEqual(retriedReceipt.receivedBytes,archive.count)
        phase("approved archive relayed and duplicate chunk acknowledged")
        let archives = try await plan.fetchArchives(current:current,origin:origin,target:profile,profileID:"tablet",revisionName:"Actual relay",configuration:configuration)
        try archives.prepareUnified(session:common,current:current,packageRootID:UUID(),grantOperationID:UUID(),grantRevisionID:UUID())
        phase("relayed archive qualified")
        try await refreshStatus()
        let activation = try common.retainCloudActivationRequest(requestID:UUID(),current:current)
        if let capture = ProcessInfo.processInfo.environment["SCREENPUNK_CONTROLLER_HTTP_FIXTURE_DIR"] {
            let file = URL(fileURLWithPath:capture).appendingPathComponent("native-activation.json")
            try activation.bytes.write(to:file,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        let authorization = try await NativeDeliveryActivationHTTPObservation.collect(body:activation,installation:result.installation,current:current,origin:origin,configuration:configuration)
        try common.retainCloudAuthorization(requestBody:activation,observation:authorization)
        let outcome = try common.dispatchCloudAndRetainActivatedOutcome(current:current)
        let retryOutcome = try common.dispatchCloudAndRetainActivatedOutcome(current:current)
        XCTAssertEqual(retryOutcome.bytes,outcome.bytes)
        phase("activation committed with identical retry outcome")
        let content = try common.selectedContent(operationID:UUID())
        try common.confirmMountedLocalContent(content)
        XCTAssertEqual(try client.queryActiveState().activeGenerationId,try common.validatedAssociation().generationID.uuidString.lowercased())
        let reviewedBase = try XCTUnwrap(UUID(uuidString:XCTUnwrap(review["expectedGenerationId"] as? String)))
        try common.retainCloudCheckpoint(authenticatedGenerationID:reviewedBase)
        let committedObservation = try XCTUnwrap(common.pendingCloudObservation())
        try await result.installation.makeUnifiedCloudObservationRequest(origin:origin,current:current,observation:committedObservation).performFixedTransport(configuration:configuration)
        let mounted = try common.confirmMountedContent(content,current:current)
        _ = try await result.installation.makeMountedContentObservationRequest(origin:origin,current:current,observation:mounted).performFixedTransport(configuration:configuration)
        let acknowledged = try await NativeDeliveryReceiptHTTPObservation.collect(body:outcome,installation:result.installation,origin:origin,configuration:configuration)
        _ = try common.retainCloudOutcomeAcknowledgment(body:outcome,observation:acknowledged)
        phase("genuine mounted receipt acknowledged")
    }
}
private struct JoinedTokens: CloudNativeTokenProvider { let token:String; func idToken() async throws -> String { token } }
private enum JoinedFailure: Error { case controllerAdmission }
#endif
