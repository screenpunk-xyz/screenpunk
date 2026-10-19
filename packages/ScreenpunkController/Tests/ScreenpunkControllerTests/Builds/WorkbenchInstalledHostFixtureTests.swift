import XCTest
import Foundation
import CryptoKit
import Darwin
@testable import ScreenpunkController

#if os(macOS)
private struct HostFixtureDocuments: WorkspaceDocumentsResolver {
    let path: URL
    func documentsDirectory() throws -> URL { path }
}
private final class HostFixtureAnchor: ToolchainTrustAnchoring {
    var value: ToolchainTrustCheckpoint?
    func read() throws -> ToolchainTrustCheckpoint? { value }
    func commit(_ checkpoint: ToolchainTrustCheckpoint) throws { value = checkpoint }
}
private struct HostFixtureSignature: ToolchainExecutableSignatureVerifying,
                                    ToolchainHostBundleSignatureVerifying {
    func verify(fd: Int32, path: String, expected: ToolchainPublisher) throws {
        guard expected.teamIdentifier == "TESTTEAM00" else { throw ToolchainTrustError.publisherUnverified }
    }
    func verify(bundlePath: String, expected: ToolchainPublisher) throws {
        guard expected.signingIdentifier == "test.build-host" else {
            throw ToolchainTrustError.publisherUnverified
        }
    }
}
private struct HostFixtureNoFetch: ToolchainArtifactFetching {
    func fetch(_ url: URL, writeChunk: @escaping (Data) throws -> Void) throws {
        throw ToolchainTrustError.trustUnavailable
    }
}

final class WorkbenchInstalledHostFixtureTests: XCTestCase {
    func testSyntheticCatalogHostBuildsBothTemplatesAndPublishesContainedHistory() throws {
        guard let fixturePath = ProcessInfo.processInfo.environment["SCREENPUNK_TEST_HOST_UNIT"],
              let templatePath = ProcessInfo.processInfo.environment["SCREENPUNK_TEST_TEMPLATES"] else {
            throw XCTSkip("Set SCREENPUNK_TEST_HOST_UNIT and SCREENPUNK_TEST_TEMPLATES for the ad-hoc signed fixture")
        }
        let unit = URL(fileURLWithPath: fixturePath)
        let root = URL(fileURLWithPath: "/private/tmp/sp-installed-host-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
                for case let path as URL in walker where path.hasDirectoryPath {
                    _ = chmod(path.path, 0o700)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        let catalogRoot = root.appendingPathComponent("catalog")
        let installedRoot = root.appendingPathComponent("installed")
        let documents = root.appendingPathComponent("Documents")
        for directory in [catalogRoot, installedRoot, documents] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let hostPublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "test.build-host")
        let servicePublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "test.build-service")
        let nodePublisher = ToolchainPublisher(teamIdentifier: "TESTTEAM00", signingIdentifier: "test.node")
        let inventory = try inventory(at: unit, host: hostPublisher, service: servicePublisher, node: nodePublisher)
        let entry = ToolchainCatalogEntry(catalogEntryId: "fixture", kind: "authoringKit",
            version: "1.0.0", platform: "darwin-arm64",
            artifactSha256: String(repeating: "a", count: 64), artifactBytes: 0,
            downloadURL: "https://fixture.invalid/kit.tar", publisher: hostPublisher,
            inventoryHash: try ToolchainCanonical.inventoryHash(inventory),
            inventory: inventory, protocolMajor: nil)
        try entry.validate()
        let installedName = entry.catalogEntryId + "-" + String(entry.inventoryHash.prefix(16))
        try cloneTree(unit, to: installedRoot.appendingPathComponent(installedName))
        let signer = Curve25519.Signing.PrivateKey()
        let policy = try ToolchainTrustPolicy(signers: ["fixture": .init(
            publicKey: signer.publicKey.rawRepresentation,
            validFrom: Date().addingTimeInterval(-3_600),
            validUntil: Date().addingTimeInterval(3_600), revoked: false)],
            channel: "stable", acceptedSequence: 1, knownHistoricalEnvelopeHashes: [],
            allowedOrigins: ["https://fixture.invalid"],
            approvedPublishers: [hostPublisher, servicePublisher, nodePublisher],
            installedKitRoot: installedRoot.path)
        let catalog = try DurableToolchainCatalogStore(root: catalogRoot.path, basePolicy: policy,
            anchor: HostFixtureAnchor(), now: Date.init, nativeSignature: HostFixtureSignature())
        let payload = ToolchainCatalogPayload(catalogVersion: 1, catalogId: "fixture",
                                              channel: "stable", sequence: 1, entries: [entry])
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(payload))
        var message = Data("screenpunk/release-catalog/v1".utf8); message.append(0)
        message.append(try ToolchainCanonical.encode(object))
        let envelope = ToolchainCatalogEnvelope(signatureVersion: 1, algorithm: "Ed25519",
            signerKeyId: "fixture", signatureBase64: try signer.signature(for: message).base64EncodedString(),
            payload: payload)
        try catalog.accept(JSONEncoder().encode(envelope))
        let installer = ToolchainKitInstaller(catalog: catalog, installedRoot: installedRoot.path,
            fetcher: HostFixtureNoFetch(), bundleSignature: HostFixtureSignature())
        let requirement = WorkspaceToolchainRequirements.Requirement(
            catalogEntryId: entry.catalogEntryId, kitVersion: entry.version,
            platform: entry.platform, inventoryHash: entry.inventoryHash)
        let workspace = try WorkspaceStore(documents: HostFixtureDocuments(path: documents),
            machineRootPath: root.appendingPathComponent("machine").path)
        let visible = root.appendingPathComponent("visible")
        _ = try workspace.create(at: visible.path)
        let files = try WorkspaceFiles(path: visible.path)
        let toolchains = try files.directory(["Workbench", "Toolchains"])
        defer { close(toolchains) }
        let requirementObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(requirement))
        try files.write(toolchains, "requirements.json",
            data: try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "required": [requirementObject]], options: [.sortedKeys]),
            expected: WorkspaceNodeID(try files.metadata(toolchains, "requirements.json")))
        let authoring = WorkbenchContainedAuthoring(workspace: workspace)
        let coordinator = WorkbenchBuildCoordinator(workspace: workspace,
            host: WorkbenchBuildHostAdapter(installer: installer))
        for starter in ["earthquakes", "gallery"] {
            let project = try authoring.create(name: starter, kind: "react", trustedKitVersion: entry.version)
            let source = URL(fileURLWithPath: templatePath).appendingPathComponent(starter)
            let config = try Data(contentsOf: source.appendingPathComponent("screen.json"))
            let main = try Data(contentsOf: source.appendingPathComponent("src/main.tsx"))
            var changes = [WorkbenchSourceChange(path: "screen.json", bytes: config),
                           WorkbenchSourceChange(path: "src/main.tsx", bytes: main)]
            let data = source.appendingPathComponent("src/data.ts")
            if FileManager.default.fileExists(atPath: data.path) {
                changes.append(.init(path: "src/data.ts", bytes: try Data(contentsOf: data)))
            }
            let updated = try authoring.patch(project.project.projectId,
                expectedSourceVersion: project.sourceVersion, changes: changes)
            let built = try coordinator.build(projectID: project.project.projectId,
                expectedSourceVersion: updated.sourceVersion, baseRevision: nil)
            let reopened = try XCTUnwrap(coordinator.readHead(projectID: project.project.projectId))
            XCTAssertEqual(reopened.0, built.head)
            XCTAssertNotNil(reopened.1.files["index.html"])
            XCTAssertNotNil(reopened.1.files["screen.js"])
            XCTAssertEqual(reopened.1.manifest.digest, built.head.digest)
            print("verified installed host fixture: \(starter), \(reopened.1.files.count) package files")
        }
        let firstProject = try XCTUnwrap(authoring.list().first)
        let prior = try XCTUnwrap(coordinator.readHead(projectID: firstProject.projectId)?.0)
        let changedRequirement = WorkspaceToolchainRequirements.Requirement(
            catalogEntryId: entry.catalogEntryId, kitVersion: entry.version,
            platform: entry.platform, inventoryHash: String(repeating: "b", count: 64))
        let changedObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(changedRequirement))
        try files.write(toolchains, "requirements.json",
            data: try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "required": [changedObject]], options: [.sortedKeys]),
            expected: WorkspaceNodeID(try files.metadata(toolchains, "requirements.json")))
        let current = try authoring.get(firstProject.projectId)
        XCTAssertThrowsError(try coordinator.build(projectID: firstProject.projectId,
            expectedSourceVersion: current.sourceVersion, baseRevision: prior.revision))
        XCTAssertEqual(try coordinator.readHead(projectID: firstProject.projectId)?.0, prior)
    }

    private func inventory(at root: URL, host: ToolchainPublisher, service: ToolchainPublisher,
                           node: ToolchainPublisher) throws -> [ToolchainInventoryItem] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey], options: []) else {
            throw WorkspaceError.unavailable
        }
        var result: [ToolchainInventoryItem] = []
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let info = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw WorkspaceError.unsafeFile }
            if info.isRegularFile != true { continue }
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { throw WorkspaceError.unsafeFile }
            let executable = metadata.st_mode & 0o111 != 0
            let publisher: ToolchainPublisher? = executable
                ? (relative == ToolchainHostBundleContract.bundle + "/Contents/MacOS/ScreenpunkBuildHost"
                    ? host : (relative == ToolchainHostBundleContract.service +
                        "/Contents/MacOS/ScreenpunkBuildService" ? service : node)) : nil
            let bytes = try Data(contentsOf: url)
            result.append(.init(path: relative, sha256: DeploymentDigest.sha256Hex(bytes),
                                bytes: bytes.count, role: executable ? "executable" : "resource",
                                publisher: publisher))
        }
        return result.sorted { ToolchainCanonical.utf8Less($0.path, $1.path) }
    }

    private func cloneTree(_ source: URL, to target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard let walker = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw WorkspaceError.unavailable
        }
        var directories: [URL] = [target]
        for case let url as URL in walker {
            let relative = String(url.path.dropFirst(source.path.count + 1))
            let destination = target.appendingPathComponent(relative)
            let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard info.isSymbolicLink != true else { throw WorkspaceError.unsafeFile }
            if info.isDirectory == true {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                directories.append(destination)
            } else if info.isRegularFile == true {
                guard clonefile(url.path, destination.path, 0) == 0 else { throw WorkspaceError.unavailable }
            } else { throw WorkspaceError.unsafeFile }
        }
        for directory in directories.reversed() {
            guard chmod(directory.path, 0o500) == 0 else { throw WorkspaceError.unavailable }
        }
    }
}
#endif
