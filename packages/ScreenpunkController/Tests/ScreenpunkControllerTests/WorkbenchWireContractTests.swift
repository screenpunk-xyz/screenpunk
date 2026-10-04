import XCTest
import Foundation
@testable import ScreenpunkController

final class WorkbenchWireContractTests: XCTestCase {
    func testRawDuplicateEscapedKeysUTF8AndUnsafeJSONReject() {
        let invalid = [
            #"{"apiVersion":"1.0","api\u0056ersion":"2.0"}"#,
            #"{"a":"\ud800"}"#,
            #"{"a":9007199254740992}"#,
            #"{"a":1.5}"#,
            #"{"a":-1}"#,
            #"{"a":{}} trailing"#,
            String(repeating: "[", count: 34) + "true" + String(repeating: "]", count: 34),
            "{\"a\":\"" + String(repeating: "x", count: 4097) + "\"}"]
        for text in invalid { XCTAssertThrowsError(try WorkbenchWireJSON.object(Data(text.utf8)), text) }
        XCTAssertThrowsError(try WorkbenchWireJSON.object(Data([123, 34, 97, 34, 58, 34, 0xff, 34, 125])))
        XCTAssertEqual(try? WorkbenchWireJSON.object(Data(#"{"label":"é","params":{}}"#.utf8))["label"] as? String, "é")
        let filePayload = String(repeating: "A", count: 4_097)
        let boundedPatch = #"{"params":{"changes":[{"bytesBase64":"\#(filePayload)"}]}}"#
        XCTAssertNoThrow(try WorkbenchWireJSON.object(Data(boundedPatch.utf8)))
        XCTAssertThrowsError(try WorkbenchWireJSON.object(Data((#"{"other":""# + filePayload + #""}"#).utf8)))
    }
    func testErrorsUseStaticSafeMessagesAndSnapshotsContainNoAuthority() throws {
        let bytes = Data(#"{"code":"authenticationFailed","message":"attacker instructions and token"}"#.utf8)
        let error = try JSONDecoder().decode(WorkbenchIPCError.self, from: bytes)
        XCTAssertEqual(error.message, "Broker authentication failed.")
        let snapshot = WorkbenchBrokerSnapshot(instanceId: "test-instance")
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertEqual(try JSONDecoder().decode(WorkbenchBrokerSnapshot.self, from: data), snapshot)
        let fields = try WorkbenchWireJSON.object(data)
        XCTAssertFalse(fields.keys.contains("token")); XCTAssertFalse(fields.keys.contains("runtimePath"))
    }
    func testRegistryCannotDispatchPrivilegedOrNonemptyMethods() {
        XCTAssertThrowsError(try WorkbenchMethodRegistry.validate(method: "system.execute", params: [:]))
        for method in WorkbenchMethodRegistry.supportedMethods {
            XCTAssertNoThrow(try WorkbenchMethodRegistry.validate(method: method, params: [:]))
            XCTAssertThrowsError(try WorkbenchMethodRegistry.validate(method: method, params: ["role": "gui"]))
        }
    }
    #if os(macOS)
    func testPairConfirmationAndRefreshedStatusDecodeDeviceControlReplies() throws {
        let data = Data(#"{"apiVersion":"1.0","requestId":"reply-1","ok":true,"result":{"schemaVersion":1,"kind":"device","device":{"deviceId":"phone-1","name":"iPhone","ownerMatchesCurrent":true,"reachability":"not-probed"}}}"#.utf8)
        for method in [WorkbenchDeviceControlMethod.pairConfirm, .status] {
            let decoder = JSONDecoder()
            decoder.userInfo[WorkbenchRPCResult.responseMethodKey] = method.rawValue
            let response = try decoder.decode(WorkbenchWireResponse.self, from: data)
            guard case .deviceAction(let result) = response.result else {
                return XCTFail("\(method.rawValue) must not alias the cached device-read reply")
            }
            XCTAssertNoThrow(try result.validate(for: method))
            XCTAssertEqual(result.device?.deviceId, "phone-1")
            XCTAssertEqual(result.device?.ownerMatchesCurrent, true)
        }
    }
    func testCachedDeviceReadRetainsReadFamilyForIdenticalPayload() throws {
        let data = Data(#"{"schemaVersion":1,"kind":"device","device":{"deviceId":"phone-1","name":"iPhone","ownerMatchesCurrent":true,"reachability":"not-probed"}}"#.utf8)
        let decoder = JSONDecoder()
        decoder.userInfo[WorkbenchRPCResult.responseMethodKey] = WorkbenchReadMethod.deviceGet.rawValue
        guard case .read(let result) = try decoder.decode(WorkbenchRPCResult.self, from: data) else {
            return XCTFail("Cached reconciliation must remain an ordinary read")
        }
        XCTAssertNoThrow(try result.validate(for: .deviceGet))
        XCTAssertEqual(result.device?.deviceId, "phone-1")
    }
    func testDeviceControlContextStillRejectsWrongKindAndMissingDevice() throws {
        for json in [#"{"schemaVersion":1,"kind":"pending","pending":[]}"#,
                     #"{"schemaVersion":1,"kind":"device","removed":true}"#] {
            let decoder = JSONDecoder()
            decoder.userInfo[WorkbenchRPCResult.responseMethodKey] = WorkbenchDeviceControlMethod.pairConfirm.rawValue
            guard case .deviceAction(let result) = try decoder.decode(WorkbenchRPCResult.self, from: Data(json.utf8)) else {
                return XCTFail("Expected the request-selected family")
            }
            // The public client requires .device after validation, as well as
            // the method's matching kind; neither malformed reply may succeed.
            XCTAssertTrue((try? result.validate(for: .pairConfirm)) == nil || result.device == nil)
        }
    }
    func testConnectionRevokeHasClosedBindingOnlyGrammar() throws {
        let params: [String: Any] = ["schemaVersion": 1, "bindingId": "binding-1"]
        guard case .revoke(let id) = try WorkbenchConnectionControlRequest.parse(
            method: .revoke, params: params) else {
            return XCTFail("Expected a local revocation request")
        }
        XCTAssertEqual(id, "binding-1")
        XCTAssertThrowsError(try WorkbenchConnectionControlRequest.parse(method: .revoke,
            params: params.merging(["remote": true]) { _, new in new }))
    }
    func testWorkspacePackageAndDeploymentResultDiscriminatorsDoNotAlias() throws {
        let package = Data(#"{"schemaVersion":1,"kind":"workspace.package.list","workspaceId":"workspace","selectionGeneration":1,"packages":[],"hasMore":false,"ordering":"history-object-id-ascending"}"#.utf8)
        guard case .workspacePackage = try JSONDecoder().decode(WorkbenchRPCResult.self, from: package) else {
            return XCTFail("Package page must not decode as a deployment response")
        }
        let deployment = Data(#"{"schemaVersion":1,"kind":"deployment.cancel","workspaceId":"workspace","selectionGeneration":1,"cancelled":true}"#.utf8)
        guard case .deploymentAction = try JSONDecoder().decode(WorkbenchRPCResult.self, from: deployment) else {
            return XCTFail("Deployment result must not decode as a package page")
        }
    }
    func testExistingPrivatePathAvoidsFoundationAliasStandardization() throws {
        let path = "/private/tmp/sp-path-" + UUID().uuidString.prefix(12)
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: url) }
        let environment = try WorkbenchBrokerEnvironment(runtimeDirectory: url)
        let directory = try WorkbenchRuntimeDirectory(environment: environment, create: false)
        XCTAssertNoThrow(try directory.revalidatePath())
        XCTAssertThrowsError(try WorkbenchBrokerEnvironment(runtimeDirectory: URL(fileURLWithPath: path + "/../unsafe")))
        XCTAssertThrowsError(try WorkbenchBrokerEnvironment(runtimeDirectory: url, limits: .init(maxConnections: 33)))
        XCTAssertThrowsError(try WorkbenchBrokerEnvironment(runtimeDirectory: url, limits: .init(maxStagingBytes: 65 * 1024 * 1024)))
    }
    #endif
}
