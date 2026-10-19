import Foundation
import XCTest
@testable import ScreenpunkController

final class WorkspaceMetadataTests: XCTestCase {
    func testValidPortableMetadataRoundTripsWithoutFilesystemState() throws {
        let descriptor = WorkspaceDescriptor(name: "Portable fixture")
        let decoded = try decodeDescriptor(WorkspaceJSON.encode(descriptor))
        XCTAssertEqual(decoded, descriptor)
        let project = WorkspaceProject(projectId: "project", dashboardId: "dashboard", name: "Screen",
            location: .contained("Screens/screen"))
        let catalog = WorkspaceCatalog(projects: [project], archivedDashboardIds: ["old-screen"])
        let decodedCatalog = try WorkspaceJSON.decode(WorkspaceCatalog.self, from: WorkspaceJSON.encode(catalog), shape: .catalog)
        try decodedCatalog.validate(); XCTAssertEqual(decodedCatalog, catalog)
        let settings = WorkspaceSettings(presentation: ["theme": "dark"], profiles: ["laptop": ["view": "grid"]],
            screenIcons: ["dashboard": "clock.fill"])
        let decodedSettings = try WorkspaceJSON.decode(WorkspaceSettings.self, from: WorkspaceJSON.encode(settings), shape: .settings)
        try decodedSettings.validate(); XCTAssertEqual(decodedSettings, settings)
        let connections = try WorkspaceJSON.decode(WorkspaceConnections.self,
            from: WorkspaceJSON.encode(WorkspaceConnections()), shape: .connections)
        try connections.validate(); XCTAssertTrue(connections.connections.isEmpty)
        let requirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self,
            from: WorkspaceJSON.encode(WorkspaceToolchainRequirements()), shape: .requirements)
        try requirements.validate(); XCTAssertTrue(requirements.required.isEmpty)
    }

    func testDuplicateKeysIncludingEscapedAliasesAreRejected() throws {
        let original = String(decoding: try WorkspaceJSON.encode(WorkspaceDescriptor(name: "Fixture")), as: UTF8.self)
        for duplicate in ["\"generation\":1,\"generation\":2", "\"generation\":1,\"genera\\u0074ion\":2"] {
            let wire = original.replacingOccurrences(of: "\"generation\":1", with: duplicate)
            expect(.invalidSchema) { _ = try self.decodeDescriptor(Data(wire.utf8)) }
        }
    }

    func testUnknownTopLevelAndNestedAuthorityFieldsAreRejected() throws {
        var object = try descriptorObject()
        object["controllerToken"] = "fixture-only"
        expect(.invalidSchema) { _ = try self.decodeDescriptor(self.data(object)) }
        object = try descriptorObject()
        var recovery = object["recovery"] as! [String: Any]
        recovery["deviceAuthority"] = "owner"
        object["recovery"] = recovery
        expect(.invalidSchema) { _ = try self.decodeDescriptor(self.data(object)) }
    }

    func testPortableNumbersRejectFractionsExponentsBooleansAndUnsafeIntegers() throws {
        let original = String(decoding: try WorkspaceJSON.encode(WorkspaceDescriptor(name: "Fixture")), as: UTF8.self)
        for token in ["-1", "1.5", "1e0", "true", "9007199254740992"] {
            let wire = original.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":\(token)")
            expect(.invalidSchema) { _ = try self.decodeDescriptor(Data(wire.utf8)) }
        }
        let wire = original.replacingOccurrences(of: "\"generation\":1", with: "\"generation\":9007199254740991")
        XCTAssertEqual(try decodeDescriptor(Data(wire.utf8)).generation, WorkspaceValidation.maxUInt)
    }

    func testRawParserEnforcesByteDepthStringAndCompleteDocumentBounds() throws {
        expect(.limitExceeded) { _ = try WorkspaceJSON.object(from: Data(repeating: 32, count: 5 * 1024 * 1024 + 1)) }
        expect(.limitExceeded) { _ = try WorkspaceJSON.object(from: Data([0xff])) }
        let nested = "{\"nested\":" + String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34) + "}"
        expect(.limitExceeded) { _ = try WorkspaceJSON.object(from: Data(nested.utf8)) }
        let string = "{\"text\":\"" + String(repeating: "x", count: 16_385) + "\"}"
        expect(.limitExceeded) { _ = try WorkspaceJSON.object(from: Data(string.utf8)) }
        expect(.invalidSchema) { _ = try WorkspaceJSON.object(from: Data("{} true".utf8)) }
        XCTAssertEqual(try WorkspaceJSON.object(from: Data("{\"value\":-1.25e2}".utf8))["value"] as? Double, -125)
        XCTAssertThrowsError(try WorkspaceJSON.object(from: Data("{\"value\":1e+}".utf8)))
    }

    func testCatalogRejectsDuplicateIdentityAndPortableLocationCollisions() throws {
        let first = WorkspaceProject(projectId: "one", dashboardId: "dash-one", name: "One", location: .contained("Screens/Café"))
        let alias = WorkspaceProject(projectId: "two", dashboardId: "dash-two", name: "Two", location: .contained("Screens/Cafe\u{0301}"))
        expect(.conflict) { try WorkspaceCatalog(projects: [first, alias]).validate() }
        expect(.invalidSchema) { try WorkspaceCatalog(projects: [first, first]).validate() }
        let external = WorkspaceProject(projectId: "three", dashboardId: "dash-three", name: "Three", location: .external("reference"))
        let duplicateReference = WorkspaceProject(projectId: "four", dashboardId: "dash-four", name: "Four", location: .external("reference"))
        expect(.conflict) { try WorkspaceCatalog(projects: [external, duplicateReference]).validate() }
        expect(.invalidSchema) { try WorkspaceCatalog(archivedDashboardIds: ["z", "a"]).validate() }
        expect(.invalidSchema) { try WorkspaceCatalog(archivedDashboardIds: ["same", "same"]).validate() }
    }

    func testVersionOneDefaultsAndVersionTwoFieldsHaveClosedSchemas() throws {
        let catalog = try WorkspaceJSON.decode(WorkspaceCatalog.self,
            from: Data("{\"schemaVersion\":1,\"generation\":1,\"projects\":[]}".utf8), shape: .catalog)
        try catalog.validate(); XCTAssertTrue(catalog.archivedDashboardIds.isEmpty)
        let settings = try WorkspaceJSON.decode(WorkspaceSettings.self,
            from: Data("{\"schemaVersion\":1,\"generation\":1,\"presentation\":{},\"profiles\":{}}".utf8), shape: .settings)
        try settings.validate(); XCTAssertTrue(settings.screenIcons.isEmpty)
        expect(.invalidSchema) {
            _ = try WorkspaceJSON.decode(WorkspaceCatalog.self,
                from: Data("{\"schemaVersion\":2,\"generation\":1,\"projects\":[]}".utf8), shape: .catalog)
        }
        var descriptor = try descriptorObject(); descriptor["schemaVersion"] = 2
        expect(.newerSchema) { _ = try self.decodeDescriptor(self.data(descriptor)) }
    }

    func testPortableSettingsCannotRepresentOperationalAuthority() throws {
        for preferences in [["controllerToken": "fixture"], ["theme": "custom"], ["defaultCollection": "../outside"]] {
            expect(.invalidSchema) { try WorkspaceSettings(presentation: preferences).validate() }
        }
        expect(.invalidSchema) { try WorkspaceSettings(screenIcons: ["dashboard": "../secret"]).validate() }
        expect(.invalidSchema) { try WorkspaceSettings(profiles: ["../machine": ["view": "grid"]]).validate() }
        try WorkspaceSettings(screenIcons: ["dashboard": "clock.fill"]).validate()
    }

    func testRequirementsAndLogicalConnectionsRejectInvalidOrCredentialFields() throws {
        let valid: [String: Any] = ["schemaVersion": 1, "required": [["catalogEntryId": "offline", "kitVersion": "1.0",
            "platform": "darwin-arm64", "inventoryHash": String(repeating: "a", count: 64)]]]
        let requirements = try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self, from: data(valid), shape: .requirements)
        try requirements.validate()
        var invalid = valid
        var rows = valid["required"] as! [[String: Any]]; rows[0]["platform"] = "linux-x64"; invalid["required"] = rows
        expect(.invalidSchema) {
            try WorkspaceJSON.decode(WorkspaceToolchainRequirements.self, from: self.data(invalid), shape: .requirements).validate()
        }
        let credential: [String: Any] = ["schemaVersion": 1, "connections": [["serviceId": "home", "kind": "homeassistant",
            "label": "Home", "authRef": "fixture-only"]]]
        expect(.invalidSchema) { _ = try WorkspaceJSON.decode(WorkspaceConnections.self, from: self.data(credential), shape: .connections) }
    }

    func testIdentifiersAndPathsRejectTraversalAndControlCharacters() {
        XCTAssertTrue(WorkspaceValidation.id("project-1"))
        for value in ["", ".project", "../outside", "é", "with space"] { XCTAssertFalse(WorkspaceValidation.id(value), value) }
        XCTAssertTrue(WorkspaceValidation.member("Screens/clock"))
        for value in ["../outside", "/absolute", "Screens//clock", "Screens/../clock", "C:/clock", "clock\\entry", "clock\0entry"] {
            XCTAssertFalse(WorkspaceValidation.member(value), value)
        }
        XCTAssertTrue(WorkspaceValidation.absolute("/private/tmp/workspace"))
        for value in ["/", "relative", "/tmp//workspace", "/tmp/../outside", "/tmp/workspace\0"] {
            XCTAssertFalse(WorkspaceValidation.absolute(value), value)
        }
    }

    func testProjectDocumentMustMatchCatalogIdentityAndSourceKind() throws {
        let project = WorkspaceProject(projectId: "project", dashboardId: "dashboard", name: "Screen", location: .contained("Screens/screen"))
        let document = WorkspaceProjectDocument(schemaVersion: 1, projectId: "project", dashboardId: "dashboard", name: "Screen",
            kind: "react", kitVersion: "1.0", entry: "src/main.tsx", screenConfig: "screen.json")
        try document.validate(matching: project)
        let wrong = WorkspaceProjectDocument(schemaVersion: 1, projectId: "other", dashboardId: "dashboard", name: "Screen",
            kind: "react", kitVersion: "1.0", entry: "index.html", screenConfig: "screen.json")
        expect(.invalidSchema) { try wrong.validate(matching: project) }
    }

    private func descriptorObject() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: WorkspaceJSON.encode(WorkspaceDescriptor(name: "Fixture"))) as! [String: Any]
    }

    private func data(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func decodeDescriptor(_ data: Data) throws -> WorkspaceDescriptor {
        let descriptor = try WorkspaceJSON.decode(WorkspaceDescriptor.self, from: data, shape: .descriptor)
        try descriptor.validate(); return descriptor
    }

    private func expect(_ error: WorkspaceError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual($0 as? WorkspaceError, error, file: file, line: line)
        }
    }
}
