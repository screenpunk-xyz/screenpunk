import XCTest
import ScreenpunkController
@testable import ScreenpunkBrokerMCP
import ScreenpunkCore
@testable import screenpunk_mcp

final class LegacyBrokerAdapterTests: XCTestCase {
    func testScreenMutationToolsAreClosedAndSubmittedLossIsInspectBeforeRetry() throws {
        let tools = BrokerMCPToolCatalog.tools()
        XCTAssertEqual(Set(tools.map(\.name)).intersection(LegacyBrokerAdapter.screenMutationTools),
            LegacyBrokerAdapter.screenMutationTools)
        for name in LegacyBrokerAdapter.screenMutationTools {
            let tool = try XCTUnwrap(tools.first(where: { $0.name == name }))
            XCTAssertFalse(tool.readOnly)
            XCTAssertEqual(tool.schema["additionalProperties"], .bool(false))
            let marker = LegacyMutationSubmission()
            XCTAssertThrowsError(try marker.send { () throws -> Void in
                throw WorkbenchIPCError(.disconnected)
            })
            let uncertain = LegacyMutationOutcome.uncertain(name: name,
                arguments: ["dashboardId": "screen-1"],
                error: WorkbenchIPCError(.disconnected), submitted: marker.submitted)
            XCTAssertTrue(uncertain?.contains("workbench_mutation_outcome_unknown") == true)
            XCTAssertTrue(uncertain?.contains("Do not replay") == true)
            XCTAssertNil(LegacyMutationOutcome.uncertain(name: name,
                arguments: [:], error: WorkbenchIPCError(.disconnected), submitted: false))
        }
        let id = "workspace-1", hash = String(repeating: "a", count: 64)
        let fields: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": id, "expectedSelectionGeneration": 2,
            "expectedCatalogGeneration": 3, "dashboardId": "screen-1",
            "expectedRevision": "revision-1", "expectedDigest": hash, "name": "Updated"]
        _ = try WorkbenchScreenPackageRenameRequest.parse(fields)
        var injected = fields; injected["role"] = "gui"
        XCTAssertThrowsError(try WorkbenchScreenPackageRenameRequest.parse(injected))
        let archived = try XCTUnwrap(tools.first(where: { $0.name == "archive_screen" }))
        XCTAssertTrue(archived.destructive)
        XCTAssertNotNil(archived.schema["oneOf"])
        let sourceOnly: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": id, "expectedSelectionGeneration": 2,
            "expectedCatalogGeneration": 3, "dashboardId": "screen-1",
            "projectId": "project-1", "expectedSourceVersion": hash]
        _ = try WorkbenchScreenArchiveRequest.parse(sourceOnly)
        var mixed = sourceOnly; mixed["expectedRevision"] = "revision-1"
        mixed["expectedDigest"] = hash
        XCTAssertThrowsError(try WorkbenchScreenArchiveRequest.parse(mixed))
        injected = fields; injected["expectedCatalogGeneration"] = true
        XCTAssertThrowsError(try WorkbenchScreenPackageRenameRequest.parse(injected))
    }

    func testIntentAndImportPreflightLossIsDistinctFromSubmittedMutationLoss() {
        for name in ["request_connection_intent", "begin_workspace_package_import",
                     "send_workspace_package_import_chunk", "commit_workspace_package_import"] {
            let preflight = LegacyMutationSubmission()
            // Fake read-only transport fails before the mutation closure can run.
            let read: () throws -> Void = { throw WorkbenchIPCError(.disconnected) }
            XCTAssertThrowsError(try read())
            XCTAssertFalse(preflight.submitted)
            XCTAssertNil(LegacyMutationOutcome.uncertain(name: name, arguments: [:],
                error: WorkbenchIPCError(.disconnected), submitted: preflight.submitted))

            let mutation = LegacyMutationSubmission()
            // Fake mutation transport loses the response after submission.
            XCTAssertThrowsError(try mutation.send { () throws -> Void in
                throw WorkbenchIPCError(.disconnected)
            })
            XCTAssertTrue(mutation.submitted)
            XCTAssertTrue(LegacyMutationOutcome.uncertain(name: name, arguments: [:],
                error: WorkbenchIPCError(.disconnected), submitted: mutation.submitted)?
                .contains("workbench_mutation_outcome_unknown") == true)
        }
    }

    func testSubmittedMutationLossHasBoundedInspectionGuidanceWithoutReplay() {
        let result = LegacyMutationOutcome.uncertain(name: "relocate_external_screen_project",
            arguments: ["projectId": "project-1", "path": "/tmp/new-home"],
            error: WorkbenchIPCError(.disconnected), submitted: true)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("workbench_mutation_outcome_unknown") == true)
        XCTAssertTrue(result?.contains("projectId=project-1") == true)
        XCTAssertTrue(result?.contains("destinationLeaf=new-home") == true)
        XCTAssertTrue(result?.contains("Do not replay") == true)
        XCTAssertFalse(result?.contains("/tmp/") == true)
        XCTAssertNil(LegacyMutationOutcome.uncertain(name: "relocate_external_screen_project",
            arguments: [:], error: WorkbenchIPCError(.disconnected), submitted: false))
        XCTAssertNil(LegacyMutationOutcome.uncertain(name: "relocate_external_screen_project",
            arguments: [:], error: WorkbenchIPCError(.workspaceConflict), submitted: true))
        let unsafe = LegacyMutationOutcome.uncertain(name: "patch_workspace_project",
            arguments: ["projectId": "line\nsecret"],
            error: WorkbenchIPCError(.publicationOutcomeUnknown), submitted: true)
        XCTAssertNotNil(unsafe)
        XCTAssertFalse(unsafe?.contains("secret") == true)
        let applied = LegacyMutationOutcome.uncertain(name: "apply_deployment",
            arguments: ["planId": "plan-7", "idempotencyKey": "hidden"],
            error: WorkbenchIPCError(.timedOut), submitted: true)
        XCTAssertTrue(applied?.contains("planId=plan-7") == true)
        XCTAssertTrue(applied?.contains("lookup_deployment") == true)
        XCTAssertFalse(applied?.contains("hidden") == true)
    }

    func testAuthoringToolsHaveClosedInputsAndCannotChooseBrokerAuthority() throws {
        let source = String(repeating: "a", count: 64)
        let valid: [(WorkbenchAuthoringRecoveryMethod, [String: Any])] = [
            (.projectCreate, ["name": "Demo", "kind": "web"]),
            (.projectOpenContained, ["path": "/tmp/contained-screen"]),
            (.projectInspect, ["projectId": "project-1"]),
            (.projectPatch, ["projectId": "project-1", "expectedSourceVersion": source,
                             "changes": [["path": "web/index.html", "bytesBase64": Data("<h1>Hi</h1>".utf8).base64EncodedString()]]]),
            (.buildRun, ["projectId": "project-1", "expectedSourceVersion": source]),
            (.buildHead, ["projectId": "project-1"]),
            (.packageHistory, [:])
        ]
        XCTAssertTrue(Set(valid.map { $0.0.rawValue }).isSubset(
            of: Set(LegacyBrokerAdapter.authoringTools.values.map(\.rawValue))))
        for (method, arguments) in valid {
            let params = try LegacyBrokerAdapter.authoringParams(method: method, arguments: arguments)
            XCTAssertEqual(params["schemaVersion"] as? Int, 1)
            var bound = arguments
            bound["expectedWorkspaceId"] = "workspace-1"
            bound["expectedSelectionGeneration"] = 2
            let selected = try LegacyBrokerAdapter.authoringParams(method: method, arguments: bound)
            XCTAssertEqual(try WorkbenchAuthoringRecoveryRequest.parse(method: method,
                params: selected).expectedSelection?.workspaceId, "workspace-1")
            bound.removeValue(forKey: "expectedSelectionGeneration")
            XCTAssertThrowsError(try LegacyBrokerAdapter.authoringParams(method: method, arguments: bound))
            for field in ["schemaVersion", "role", "consentSource", "method", "token"] {
                var injected = arguments
                injected[field] = field == "schemaVersion" ? 1 : "gui"
                XCTAssertThrowsError(try LegacyBrokerAdapter.authoringParams(method: method, arguments: injected),
                                     "\(method.rawValue) accepted \(field)")
            }
        }
    }

    func testWorkspacePackageToolsExposeOnlyExactReadFields() {
        XCTAssertEqual(LegacyBrokerAdapter.workspacePackageTools,
                       ["list_workspace_packages", "get_workspace_package", "get_workspace_package_file"])
        let list = LegacyBrokerAdapter.packageSchema("list_workspace_packages")
        XCTAssertEqual(list["additionalProperties"], .bool(false))
        XCTAssertEqual(list["required"]?.array, [])
        let file = LegacyBrokerAdapter.packageSchema("get_workspace_package_file")
        XCTAssertEqual(Set(file["required"]?.array?.compactMap(\.string) ?? []),
                       ["dashboardId", "revision", "path", "offset"])
        XCTAssertEqual(file["properties"]?.object.map { Set($0.keys) } ?? [],
                       ["dashboardId", "revision", "path", "offset"])
    }

    func testPatchSchemaAdvertisesBothClosedChangeShapesAndByteBound() throws {
        let schema = LegacyBrokerAdapter.authoringSchema("patch_workspace_project")
        let shapes = try XCTUnwrap(schema["properties"]?["changes"]?["items"]?["oneOf"]?.array)
        XCTAssertEqual(shapes.count, 2)
        let required = shapes.map { Set($0["required"]?.array?.compactMap(\.string) ?? []) }
        XCTAssertEqual(Set(required), [["path", "bytesBase64"], ["path", "delete"]])
        XCTAssertTrue(shapes.allSatisfy { $0["additionalProperties"] == .bool(false) })
        XCTAssertEqual(shapes[0]["properties"]?["bytesBase64"]?["maxLength"], .int(6_990_508))
        XCTAssertNotNil(shapes[0]["properties"]?["bytesBase64"]?["pattern"]?.string)
        XCTAssertEqual(shapes[1]["properties"]?["delete"]?["const"], .bool(true))
        XCTAssertEqual(schema["dependentRequired"]?["expectedWorkspaceId"]?.array,
                       [.string("expectedSelectionGeneration")])
        let base: [String: Any] = ["projectId": "project-1",
            "expectedSourceVersion": String(repeating: "a", count: 64)]
        for change in [["path": "web/index.html", "bytesBase64": Data("ok".utf8).base64EncodedString()] as [String: Any],
                       ["path": "web/index.html", "delete": true]] {
            var args = base; args["changes"] = [change]
            XCTAssertNoThrow(try LegacyBrokerAdapter.authoringParams(method: .projectPatch, arguments: args))
        }
        var invalid = base
        invalid["changes"] = [["path": "web/index.html", "delete": false]]
        XCTAssertThrowsError(try LegacyBrokerAdapter.authoringParams(method: .projectPatch, arguments: invalid))
        invalid["changes"] = [["path": "web/index.html", "bytesBase64": "b2s=", "delete": true]]
        XCTAssertThrowsError(try LegacyBrokerAdapter.authoringParams(method: .projectPatch, arguments: invalid))
        var larger = base
        larger["changes"] = [["path": "web/index.html",
            "bytesBase64": Data(repeating: 65, count: 4096).base64EncodedString()]]
        XCTAssertNoThrow(try LegacyBrokerAdapter.authoringParams(method: .projectPatch, arguments: larger))
    }

    func testDeploymentToolSchemasAndClosedArguments() throws {
        XCTAssertEqual(Set(LegacyBrokerAdapter.deploymentTools.keys),
            ["prepare_deployment", "plan_deployment", "review_deployment", "apply_deployment",
             "get_deployment_status", "lookup_deployment", "reconcile_deployment"])
        let apply = LegacyBrokerAdapter.deploymentSchema("apply_deployment")
        XCTAssertEqual(apply["additionalProperties"], .bool(false))
        XCTAssertEqual(Set(apply["required"]?.array?.compactMap(\.string) ?? []),
            ["planId", "expectedPlanHash", "expectedAuthorizationContextHash", "idempotencyKey", "approved"])
        let valid: [String: Any] = ["planId": "plan-1", "expectedPlanHash": String(repeating: "a", count: 64),
            "expectedAuthorizationContextHash": String(repeating: "b", count: 64),
            "idempotencyKey": "key-1", "approved": true]
        XCTAssertEqual(try LegacyBrokerAdapter.deploymentParams(name: "apply_deployment", arguments: valid)["schemaVersion"] as? Int, 1)
        for (key, value) in [("role", "gui" as Any), ("consentSource", "terminal" as Any),
                             ("approvalMode", "scripted" as Any), ("method", "deployment.apply" as Any),
                             ("schemaVersion", 1 as Any)] {
            var extra = valid; extra[key] = value
            XCTAssertThrowsError(try LegacyBrokerAdapter.deploymentParams(name: "apply_deployment", arguments: extra))
        }
        var denied = valid; denied["approved"] = false
        XCTAssertThrowsError(try LegacyBrokerAdapter.deploymentParams(name: "apply_deployment", arguments: denied))
        for value: Any in [1, 0, "true", NSNull()] {
            denied = valid; denied["approved"] = value
            XCTAssertThrowsError(try LegacyBrokerAdapter.deploymentParams(name: "apply_deployment", arguments: denied))
        }
        denied = valid; denied["expectedAuthorizationContextHash"] = "stale"
        XCTAssertThrowsError(try LegacyBrokerAdapter.deploymentParams(name: "apply_deployment", arguments: denied))
    }

    func testNewReadSchemasAreClosed() {
        for name in LegacyBrokerAdapter.extraReadTools {
            let schema = LegacyBrokerAdapter.extraReadSchema(name)
            XCTAssertEqual(schema["additionalProperties"], .bool(false))
        }
        let set = LegacyBrokerAdapter.extraReadSchema("get_device_screen_set")
        XCTAssertEqual(set["required"]?.array, [.string("deviceId")])
        for name in ["get_device_settings", "get_device_connection_inventory", "refresh_device_status"] {
            let schema = LegacyBrokerAdapter.extraReadSchema(name)
            XCTAssertEqual(schema["required"]?.array, [.string("deviceId")])
            XCTAssertEqual(schema["properties"]?.object.map { Set($0.keys) }, ["deviceId"])
        }
        XCTAssertEqual(LegacyBrokerAdapter.workspaceSchema("initialize_workspace")["required"]?.array, [])
        XCTAssertEqual(LegacyBrokerAdapter.workspaceSchema("open_workspace")["required"]?.array,
                       [.string("path")])
        XCTAssertEqual(LegacyBrokerAdapter.workspaceSchema("open_workspace")["additionalProperties"], .bool(false))
        XCTAssertTrue(LegacyBrokerAdapter.resourceURIs.contains("screenpunk://workbench/workspace"))
        XCTAssertTrue(LegacyBrokerAdapter.resourceURIs.contains("screenpunk://deployments/plans/{id}"))
        XCTAssertEqual(LegacyBrokerAdapter.emptySchema["additionalProperties"], .bool(false))
        XCTAssertEqual(LegacyBrokerAdapter.emptySchema["properties"], .object([:]))
    }

    func testSourceChunkToolIsSelectionBoundAndClosed() throws {
        let schema = LegacyBrokerAdapter.extraReadSchema("get_workspace_source_file")
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(Set(schema["required"]?.array?.compactMap(\.string) ?? []),
            ["projectId", "path", "expectedSourceVersion", "offset"])
        XCTAssertEqual(schema["dependentRequired"]?["expectedWorkspaceId"]?.array,
            [.string("expectedSelectionGeneration")])
        var args: [String: Any] = ["projectId": "project-1", "path": "web/index.html",
            "expectedSourceVersion": String(repeating: "a", count: 64), "offset": 0]
        let request = try LegacyBrokerAdapter.sourceChunkRequest(arguments: args,
            workspaceId: "workspace-1", selectionGeneration: 2)
        XCTAssertEqual(request.expectedWorkspaceId, "workspace-1")
        XCTAssertEqual(request.expectedSelectionGeneration, 2)
        args["expectedWorkspaceId"] = "workspace-1"
        XCTAssertThrowsError(try LegacyBrokerAdapter.sourceChunkRequest(arguments: args,
            workspaceId: "workspace-1", selectionGeneration: 2))
        args["expectedSelectionGeneration"] = 2
        XCTAssertNoThrow(try LegacyBrokerAdapter.sourceChunkRequest(arguments: args,
            workspaceId: "workspace-1", selectionGeneration: 2))
        args["expectedSelectionGeneration"] = 3
        XCTAssertThrowsError(try LegacyBrokerAdapter.sourceChunkRequest(arguments: args,
            workspaceId: "workspace-1", selectionGeneration: 2))
        args["expectedSelectionGeneration"] = 2
        args["offset"] = true
        XCTAssertThrowsError(try LegacyBrokerAdapter.sourceChunkRequest(arguments: args,
            workspaceId: "workspace-1", selectionGeneration: 2))
        args["offset"] = 0
        args["role"] = "gui"
        XCTAssertThrowsError(try LegacyBrokerAdapter.sourceChunkRequest(arguments: args,
            workspaceId: "workspace-1", selectionGeneration: 2))
    }

    func testOrdinaryConnectionIntentProposalRejectsAuthorityAndSecretFields() throws {
        let device = UUID().uuidString.lowercased()
        let dashboard = UUID().uuidString.lowercased()
        let revision = UUID().uuidString.lowercased()
        let grantId = UUID().uuidString.uppercased()
        let grant: [String: Any] = ["schemaVersion": 1, "id": grantId,
            "alias": "status", "origin": "https://example.test", "transport": "http",
            "authRef": "", "lan": false, "allowInsecureHTTP": false,
            "operations": [["name": "read", "kind": "http", "method": "GET",
                            "path": "/status", "idempotent": true, "write": false]]]
        var args: [String: Any] = ["deviceId": device, "dashboardId": dashboard,
            "revision": revision, "grant": grant,
            "auth": ["authRef": "", "placement": "none"]]
        let parsed = try LegacyBrokerAdapter.connectionIntentProposal(args)
        XCTAssertEqual(parsed.deviceId, device)
        XCTAssertEqual(parsed.grant.operations.count, 1)
        try LegacyBrokerAdapter.checkIntentSelection(args,
            workspaceId: "workspace-1", generation: 2)
        args["expectedWorkspaceId"] = "workspace-1"
        XCTAssertThrowsError(try LegacyBrokerAdapter.checkIntentSelection(args,
            workspaceId: "workspace-1", generation: 2))
        args["expectedSelectionGeneration"] = 2
        XCTAssertNoThrow(try LegacyBrokerAdapter.checkIntentSelection(args,
            workspaceId: "workspace-1", generation: 2))
        args["expectedSelectionGeneration"] = 3
        XCTAssertThrowsError(try LegacyBrokerAdapter.checkIntentSelection(args,
            workspaceId: "workspace-1", generation: 2))
        args.removeValue(forKey: "expectedWorkspaceId")
        args.removeValue(forKey: "expectedSelectionGeneration")
        for (field, value) in [("role", "localReview" as Any),
                               ("secretBase64", "c2VjcmV0" as Any),
                               ("approve", true as Any)] {
            var injected = args; injected[field] = value
            XCTAssertThrowsError(try LegacyBrokerAdapter.connectionIntentProposal(injected))
        }
        var badAuth = args
        badAuth["auth"] = ["authRef": "", "placement": "bearer"]
        XCTAssertThrowsError(try LegacyBrokerAdapter.connectionIntentProposal(badAuth))
        badAuth["auth"] = ["authRef": "", "placement": "none", "fieldName": "Authorization"]
        XCTAssertThrowsError(try LegacyBrokerAdapter.connectionIntentProposal(badAuth))
        var badGrant = grant; badGrant["authRef"] = "token"
        var injected = args; injected["grant"] = badGrant
        XCTAssertThrowsError(try LegacyBrokerAdapter.connectionIntentProposal(injected))
        badGrant = grant; badGrant["secret"] = "token"
        injected["grant"] = badGrant
        XCTAssertThrowsError(try LegacyBrokerAdapter.connectionIntentProposal(injected))
        let schema = LegacyBrokerAdapter.connectionIntentSchema("request_connection_intent")
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["properties"]?["grant"]?["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["properties"]?["auth"]?["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["properties"]?["auth"]?["properties"]?["placement"]?["const"], .string("none"))
        XCTAssertEqual(schema["dependentRequired"]?["expectedWorkspaceId"]?.array,
            [.string("expectedSelectionGeneration")])
    }

    func testConnectionIntentResponseRetainsTargetAndExpiry() throws {
        let device = UUID().uuidString.lowercased()
        let dashboard = UUID().uuidString.lowercased()
        let revision = UUID().uuidString.lowercased()
        let grant: [String: Any] = ["schemaVersion": 1, "id": UUID().uuidString,
            "alias": "status", "origin": "https://example.test", "transport": "http",
            "authRef": "", "lan": false, "allowInsecureHTTP": false,
            "operations": [["name": "read", "kind": "http", "method": "GET",
                            "path": "/status", "idempotent": true, "write": false]]]
        let target = try LegacyBrokerAdapter.connectionIntentProposal([
            "deviceId": device, "dashboardId": dashboard, "revision": revision,
            "grant": grant, "auth": ["authRef": "", "placement": "none"]])
        var fixture: [String: Any] = ["intentId": UUID().uuidString.lowercased(),
            "declarationHash": String(repeating: "a", count: 64),
            "proposalScopeHash": try WorkbenchConnectionIntentAttestation.proposalScopeHash(
                deviceId: device, dashboardId: dashboard, revision: revision,
                grant: target.grant, auth: target.auth),
            "authorizationContextHash": String(repeating: "b", count: 64),
            "expiresAt": Date().addingTimeInterval(300).timeIntervalSinceReferenceDate,
            "state": "pending", "summary": ["bindingId": target.grant.id.uuidString.lowercased(),
                "deviceId": device, "dashboardId": dashboard, "revision": revision,
                "alias": "status", "origin": "public:example.test", "transport": "http",
                "operations": [["name": "read", "method": "GET",
                                "address": "https://example.test/status", "writes": false]],
                "authenticationPlacement": "none", "redirectPolicy": "deny_cross_origin_and_downgrade",
                "maximumResponseBytes": ConnectionBounds.httpResponseBytes,
                "timeoutSeconds": ConnectionBounds.httpTimeoutSeconds,
                "grantGeneration": 0,
                "localStatus": "pending", "remoteRevocation": "not_requested"]]
        func read(_ value: [String: Any]) throws -> WorkbenchConnectionIntentView {
            try JSONDecoder().decode(WorkbenchConnectionIntentView.self,
                from: JSONSerialization.data(withJSONObject: value))
        }
        XCTAssertNoThrow(try LegacyBrokerAdapter.validateIntentView(read(fixture), target: target))
        var forgedHash = fixture
        forgedHash["proposalScopeHash"] = String(repeating: "c", count: 64)
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateIntentView(read(forgedHash), target: target))
        func rejectChangedGrant(_ changed: ConnectionGrant, _ field: String) throws {
            let proposal = LegacyBrokerAdapter.ConnectionIntentProposal(deviceId: device,
                dashboardId: dashboard, revision: revision, grant: changed, auth: target.auth)
            XCTAssertThrowsError(try LegacyBrokerAdapter.validateIntentView(read(fixture),
                target: proposal), field)
        }
        var changed = target.grant; changed.schemaVersion += 1
        try rejectChangedGrant(changed, "schemaVersion")
        changed = target.grant; changed.id = UUID()
        try rejectChangedGrant(changed, "id")
        changed = target.grant; changed.alias = "other"
        try rejectChangedGrant(changed, "alias")
        changed = target.grant; changed.origin = "https://other.test"
        try rejectChangedGrant(changed, "origin")
        changed = target.grant; changed.transport = .ws
        try rejectChangedGrant(changed, "transport")
        changed = target.grant; changed.lan = true
        try rejectChangedGrant(changed, "lan")
        changed = target.grant; changed.allowInsecureHTTP = true
        try rejectChangedGrant(changed, "allowInsecureHTTP")
        changed = target.grant; changed.operations[0].name = "other"
        try rejectChangedGrant(changed, "operation.name")
        changed = target.grant; changed.operations[0].kind = .ws
        try rejectChangedGrant(changed, "operation.kind")
        changed = target.grant; changed.operations[0].method = .POST
        try rejectChangedGrant(changed, "operation.method")
        changed = target.grant; changed.operations[0].path = "/other"
        try rejectChangedGrant(changed, "operation.path")
        changed = target.grant; changed.operations[0].idempotent = false
        try rejectChangedGrant(changed, "operation.idempotent")
        changed = target.grant; changed.operations[0].write = true
        try rejectChangedGrant(changed, "operation.write")
        changed = target.grant; changed.operations[0].maxAgeSeconds = 60
        try rejectChangedGrant(changed, "operation.maxAgeSeconds")
        fixture["expiresAt"] = Date().addingTimeInterval(-10).timeIntervalSinceReferenceDate
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateIntentView(read(fixture), target: target))
        XCTAssertNoThrow(try LegacyBrokerAdapter.validateIntentView(read(fixture), target: nil))
        var credentialPending = fixture
        var credentialSummary = try XCTUnwrap(credentialPending["summary"] as? [String: Any])
        credentialSummary["authenticationPlacement"] = "bearer"
        credentialPending["summary"] = credentialSummary
        credentialPending["state"] = "credential_pending"
        XCTAssertNoThrow(try LegacyBrokerAdapter.validateIntentView(read(credentialPending), target: nil))
        fixture["expiresAt"] = Date().addingTimeInterval(300).timeIntervalSinceReferenceDate
        var summary = try XCTUnwrap(fixture["summary"] as? [String: Any])
        summary["dashboardId"] = UUID().uuidString.lowercased()
        fixture["summary"] = summary
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateIntentView(read(fixture), target: target))
        for (field, changed) in [("bindingId", UUID().uuidString.lowercased() as Any),
                                 ("origin", "public:other.test" as Any),
                                 ("authenticationPlacement", "bearer" as Any),
                                 ("redirectPolicy", "follow" as Any),
                                 ("maximumResponseBytes", 1 as Any)] {
            var altered = fixture
            var scope = try XCTUnwrap(altered["summary"] as? [String: Any])
            scope["dashboardId"] = dashboard
            scope[field] = changed
            altered["summary"] = scope
            XCTAssertThrowsError(try LegacyBrokerAdapter.validateIntentView(read(altered), target: target), field)
        }
        var altered = fixture
        var scope = try XCTUnwrap(altered["summary"] as? [String: Any])
        scope["dashboardId"] = dashboard
        scope["operations"] = [["name": "read", "method": "GET",
            "address": "https://example.test/other", "writes": false]]
        altered["summary"] = scope
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateIntentView(read(altered), target: target))
        let schema = LegacyBrokerAdapter.connectionIntentSchema("get_connection_intent")
        XCTAssertEqual(schema["additionalProperties"], .bool(false))
        XCTAssertEqual(schema["required"]?.array, [.string("intentId")])
    }

    func testBoundedPackageImportInputsRequireExactSelectionAndMeasuredBytes() throws {
        let file = Data("<html>import</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Imported package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let digest = try XCTUnwrap(manifest.digest)
        let common: [String: Any] = ["expectedWorkspaceId": "workspace-1",
            "expectedSelectionGeneration": 2]
        var begin = common
        begin["expectedDigest"] = digest
        begin["manifestBase64"] = try JSONEncoder().encode(manifest).base64EncodedString()
        if case .begin(let decoded, let value) = try LegacyBrokerAdapter.packageImportInput(
            name: "begin_workspace_package_import", arguments: begin,
            workspaceId: "workspace-1", generation: 2) {
            XCTAssertEqual(decoded, manifest); XCTAssertEqual(value, digest)
        } else { XCTFail("begin input parsed as another method") }
        begin["expectedSelectionGeneration"] = 3
        XCTAssertThrowsError(try LegacyBrokerAdapter.packageImportInput(
            name: "begin_workspace_package_import", arguments: begin,
            workspaceId: "workspace-1", generation: 2))
        begin["expectedSelectionGeneration"] = 2
        begin["secretBase64"] = "c2VjcmV0"
        XCTAssertThrowsError(try LegacyBrokerAdapter.packageImportInput(
            name: "begin_workspace_package_import", arguments: begin,
            workspaceId: "workspace-1", generation: 2))
        var chunk = common
        chunk["uploadId"] = "upload-1"; chunk["fileIndex"] = 0; chunk["offset"] = 0
        chunk["chunkSHA256"] = DeploymentDigest.sha256Hex(file)
        chunk["bytesBase64"] = file.base64EncodedString()
        if case .chunk(_, _, _, let bytes) = try LegacyBrokerAdapter.packageImportInput(
            name: "send_workspace_package_import_chunk", arguments: chunk,
            workspaceId: "workspace-1", generation: 2) {
            XCTAssertEqual(bytes, file)
        } else { XCTFail("chunk input parsed as another method") }
        chunk["chunkSHA256"] = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try LegacyBrokerAdapter.packageImportInput(
            name: "send_workspace_package_import_chunk", arguments: chunk,
            workspaceId: "workspace-1", generation: 2))
        chunk["chunkSHA256"] = DeploymentDigest.sha256Hex(file)
        chunk["offset"] = true
        XCTAssertThrowsError(try LegacyBrokerAdapter.packageImportInput(
            name: "send_workspace_package_import_chunk", arguments: chunk,
            workspaceId: "workspace-1", generation: 2))
        for name in LegacyBrokerAdapter.packageImportTools {
            let schema = LegacyBrokerAdapter.packageImportSchema(name)
            XCTAssertEqual(schema["additionalProperties"], .bool(false))
            XCTAssertEqual(Set(schema["required"]?.array?.compactMap(\.string) ?? []).intersection(
                ["expectedWorkspaceId", "expectedSelectionGeneration"]),
                ["expectedWorkspaceId", "expectedSelectionGeneration"])
        }
        let progress = try JSONDecoder().decode(WorkbenchPackageImportResult.self,
            from: JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "kind": "package.importChunk", "uploadId": "upload-1",
                "nextFileIndex": 1, "nextOffset": 0]))
        XCTAssertNoThrow(try LegacyBrokerAdapter.validateImportProgress(progress,
            method: .chunk, expectedUploadId: "upload-1", manifest: manifest,
            sent: (0, 0, file.count)))
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateImportProgress(progress,
            method: .chunk, expectedUploadId: "upload-2", manifest: manifest,
            sent: (0, 0, file.count)))
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateImportProgress(progress,
            method: .chunk, expectedUploadId: "upload-1", manifest: manifest,
            sent: (0, 0, file.count - 1)))
        let impossible = try JSONDecoder().decode(WorkbenchPackageImportResult.self,
            from: JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "kind": "package.importChunk", "uploadId": "upload-1",
                "nextFileIndex": 0, "nextOffset": file.count + 1]))
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateImportProgress(impossible,
            method: .chunk, expectedUploadId: "upload-1", manifest: manifest,
            sent: (0, 0, file.count)))
        let leap = try JSONDecoder().decode(WorkbenchPackageImportResult.self,
            from: JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "kind": "package.importChunk", "uploadId": "upload-1",
                "nextFileIndex": 2, "nextOffset": 0]))
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateImportProgress(leap,
            method: .chunk, expectedUploadId: "upload-1", manifest: manifest,
            sent: (0, 0, file.count)))
        let receiptFields: [String: Any] = ["schemaVersion": 1,
            "workspaceId": "workspace-1", "selectionGeneration": 2,
            "dashboardId": manifest.dashboardId, "revision": manifest.revision,
            "digest": digest, "fileCount": 1, "includedBytes": file.count,
            "storage": "workspace-history", "provenance": "imported-package-untrusted",
            "editableSourceIncluded": false, "localBindingsImported": false,
            "deploymentAuthority": "none"]
        func receipt(_ fields: [String: Any]) throws -> WorkbenchBoundedPackageImportReceipt {
            try JSONDecoder().decode(WorkbenchBoundedPackageImportReceipt.self,
                from: JSONSerialization.data(withJSONObject: fields))
        }
        XCTAssertNoThrow(try LegacyBrokerAdapter.validateImportReceipt(receipt(receiptFields),
            digest: digest, workspaceId: "workspace-1", generation: 2))
        for (field, value) in [("editableSourceIncluded", true as Any),
                               ("localBindingsImported", true as Any),
                               ("deploymentAuthority", "approved" as Any),
                               ("provenance", "local-trusted" as Any)] {
            var forged = receiptFields; forged[field] = value
            XCTAssertThrowsError(try LegacyBrokerAdapter.validateImportReceipt(receipt(forged),
                digest: digest, workspaceId: "workspace-1", generation: 2), field)
        }
    }

    func testPackageImportManifestContextHasOneBoundedExpiringUpload() throws {
        let file = Data("<html>import</html>".utf8)
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Imported package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        var now: TimeInterval = 1_000
        let registry = PackageImportManifestRegistry(now: { now })
        try registry.canBegin()
        try registry.store(manifest, uploadId: "upload-one")
        XCTAssertNotNil(registry.load("upload-one"))
        XCTAssertThrowsError(try registry.canBegin())
        XCTAssertThrowsError(try registry.store(manifest, uploadId: "upload-two"))
        XCTAssertNotNil(registry.load("upload-one"), "capacity rejection must retain active validation context")
        now = 1_119
        try registry.renew("upload-one")
        now = 1_239
        XCTAssertNil(registry.load("upload-one"), "idle expiry must fail closed")
        try registry.canBegin()
        try registry.store(manifest, uploadId: "upload-two")
        now = 1_358
        try registry.renew("upload-two")
        now = 1_477
        try registry.renew("upload-two")
        now = 1_596
        try registry.renew("upload-two")
        now = 1_715
        try registry.renew("upload-two")
        now = 1_834
        try registry.renew("upload-two")
        now = 1_839
        XCTAssertNil(registry.load("upload-two"), "absolute deadline must not be extended")
        try registry.canBegin()
        try registry.store(manifest, uploadId: "upload-three")
        registry.remove("upload-three")
        XCTAssertNil(registry.load("upload-three"))
    }

    func testBothTransportsShareOneAdvertisedCatalog() throws {
        let tools = BrokerMCPToolCatalog.tools()
        XCTAssertEqual(tools.map(\.name), tools.map(\.name).sorted())
        XCTAssertEqual(Set(tools.map(\.name)).count, tools.count)
        for name in ["get_workspace", "get_device_settings", "get_device_connection_inventory",
                     "refresh_device_status", "apply_deployment", "lookup_deployment",
                     "request_connection_intent", "get_connection_intent",
                     "begin_workspace_package_import", "commit_workspace_package_import"] {
            let tool = try XCTUnwrap(tools.first(where: { $0.name == name }))
            XCTAssertEqual(tool.schema["additionalProperties"], .bool(false))
        }
        let source = try XCTUnwrap(tools.first(where: { $0.name == "get_workspace_source_file" }))
        XCTAssertTrue(source.readOnly)
        XCTAssertEqual(source.schema["additionalProperties"], .bool(false))
        XCTAssertFalse(try XCTUnwrap(tools.first(where: { $0.name == "request_connection_intent" })).readOnly)
        XCTAssertTrue(try XCTUnwrap(tools.first(where: { $0.name == "get_connection_intent" })).readOnly)
        XCTAssertEqual(Set(tools.map(\.name)).intersection(LegacyBrokerAdapter.packageImportTools),
                       LegacyBrokerAdapter.packageImportTools)
        for item in tools {
            let fallback = BrokerMCPJSONRPC.toolJSON(item)
            let annotations = try XCTUnwrap(fallback["annotations"] as? [String: Any])
            XCTAssertEqual(annotations["title"] as? String, item.name)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, item.readOnly)
        }
        XCTAssertFalse(tools.contains(where: { $0.name == "project.sourceChunk" }))
        XCTAssertFalse(tools.contains(where: { $0.name == "preview_dashboard" }))
        XCTAssertFalse(tools.contains(where: { $0.name == "deploy_dashboard" }))
        XCTAssertTrue(tools.contains(where: { $0.name == "prepare_deployment" }))
        XCTAssertTrue(tools.contains(where: { $0.name == "begin_workspace_package_import" }))
    }

    func testExpandedSourceAndWorkspaceToolsHaveClosedSchemasAndBrokerParsers() throws {
        let id = UUID().uuidString.lowercased()
        let hash = String(repeating: "a", count: 64)
        let path = "/private/tmp/screenpunk-mcp-contract-fixture"
        let cases: [(String, [String: Any])] = [
            ("clone_workspace_project", ["projectId": id, "expectedSourceVersion": hash]),
            ("unregister_workspace_project", ["projectId": id, "expectedCatalogGeneration": 1]),
            ("export_workspace_source", ["projectId": id, "sourceVersion": hash, "path": path]),
            ("import_workspace_source", ["path": path]),
            ("open_external_screen_project", ["path": path, "explicitExternal": true]),
            ("adopt_external_screen_project", ["projectId": id, "expectedSourceVersion": hash,
                "name": "Adopted"]),
            ("relocate_external_screen_project", ["projectId": id,
                "expectedSourceVersion": hash, "path": path, "explicitExternal": true]),
            ("export_workspace_package", ["dashboardId": id, "revision": id, "path": path]),
            ("create_workspace_snapshot", ["path": path]),
            ("relocate_workspace", ["path": path]),
            ("get_workspace_config", [:]),
            ("get_workspace_config_path", [:]),
            ("set_workspace_config", ["key": "theme", "value": "dark", "expectedGeneration": 1]),
            ("unset_workspace_config", ["key": "theme", "expectedGeneration": 1])
        ]
        let tools = BrokerMCPToolCatalog.tools()
        for (name, arguments) in cases {
            let tool = try XCTUnwrap(tools.first(where: { $0.name == name }))
            XCTAssertEqual(tool.schema["additionalProperties"], .bool(false), name)
            let method = try XCTUnwrap(LegacyBrokerAdapter.authoringTools[name])
            let params = try LegacyBrokerAdapter.authoringParams(method: method, arguments: arguments)
            XCTAssertNoThrow(try WorkbenchAuthoringRecoveryRequest.parse(method: method, params: params), name)
            XCTAssertThrowsError(try LegacyBrokerAdapter.authoringParams(method: method,
                arguments: arguments.merging(["role": "gui"]) { _, new in new }), name)
            XCTAssertThrowsError(try LegacyBrokerAdapter.authoringParams(method: method,
                arguments: arguments.merging(["schemaVersion": 1]) { _, new in new }), name)
        }
        XCTAssertTrue(try XCTUnwrap(tools.first(where: { $0.name == "get_workspace_config" })).readOnly)
        XCTAssertFalse(try XCTUnwrap(tools.first(where: { $0.name == "set_workspace_config" })).readOnly)
        XCTAssertNil(LegacyBrokerAdapter.authoringTools["migration_apply"])
        XCTAssertNil(LegacyBrokerAdapter.authoringTools["resolve_connection_intent"])
    }

    func testOrdinaryManagementAllowlistRejectsExtraAuthorityAndWrongTypes() throws {
        let cases: [(String, [String: Any])] = [
            ("get_workspace_coverage", ["validate": true]),
            ("get_workspace_toolchain_requirements", [:]),
            ("list_workspace_operations", [:]),
            ("get_workspace_operation_status", ["operationId": "op-1"]),
            ("cancel_workspace_operation", ["operationId": "op-1"]),
            ("discover_devices", [:]),
            ("get_pending_pairings", [:]),
            ("begin_device_pairing", ["deviceId": "device-1"]),
            ("confirm_device_pairing", ["pendingId": "pending-1", "matchingCode": "123456"]),
            ("cancel_device_pairing", ["pendingId": "pending-1"])
        ]
        let tools = BrokerMCPToolCatalog.tools()
        for (name, arguments) in cases {
            let tool = try XCTUnwrap(tools.first(where: { $0.name == name }))
            XCTAssertEqual(tool.schema["additionalProperties"], .bool(false), name)
            XCTAssertNoThrow(try LegacyBrokerAdapter.validateManagement(name: name, arguments: arguments), name)
            XCTAssertThrowsError(try LegacyBrokerAdapter.validateManagement(name: name,
                arguments: arguments.merging(["role": "gui"]) { _, new in new }), name)
        }
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateManagement(name: "get_workspace_coverage",
            arguments: ["validate": 1]))
        XCTAssertThrowsError(try LegacyBrokerAdapter.validateManagement(name: "confirm_device_pairing",
            arguments: ["pendingId": "pending-1", "matchingCode": 123456]))
        XCTAssertFalse(BrokerMCPToolCatalog.registeredNames.contains("resolve_connection_intent"))
        XCTAssertFalse(BrokerMCPToolCatalog.registeredNames.contains("import_connection_secret"))
    }
}
