#if os(macOS)
import XCTest
import Foundation
import Darwin
import ScreenpunkCore
@testable import ScreenpunkController

final class WorkbenchDomainBrokerTests: XCTestCase {
    func testSocketPackageImportIsMeasuredBoundedAndHistoricalOnly() throws {
        let fixture = try Fixture(mutationGate: {})
        defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let file = Data((0..<200_000).map { UInt8(65 + ($0 % 26)) })
        var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: UUID().uuidString.lowercased(), name: "Transferred package",
            revision: UUID().uuidString.lowercased(), entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        manifest.digest = try DeploymentDigest.digest(for: manifest)
        let digest = try XCTUnwrap(manifest.digest)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: fixture.environment)
        try client.connect(); defer { client.close() }
        let selected = try client.workspaceStatus()
        let id = try XCTUnwrap(selected.workspaceId)
        let generation = try XCTUnwrap(selected.selectionGeneration)
        let started = try client.beginPackageImport(manifest: manifest, expectedDigest: digest,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)
        let upload = try XCTUnwrap(started.uploadId)
        XCTAssertEqual(started.nextOffset, 0)
        let other = WorkbenchBrokerClient(environment: fixture.environment)
        try other.connect(); defer { other.close() }
        XCTAssertThrowsError(try other.packageImportStatus(uploadId: upload,
            expectedWorkspaceId: UUID().uuidString.lowercased(),
            expectedSelectionGeneration: generation)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertEqual(try client.packageImportStatus(uploadId: upload,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation).uploadId, upload)
        XCTAssertThrowsError(try client.sendPackageImportChunk(uploadId: upload,
            fileIndex: 0, offset: 1, bytes: file.prefix(10),
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        try client.connect()
        var offset = 0
        while offset < file.count {
            let end = min(offset + 64 * 1024, file.count)
            let progress = try client.sendPackageImportChunk(uploadId: upload,
                fileIndex: 0, offset: offset, bytes: file.subdata(in: offset..<end),
                expectedWorkspaceId: id, expectedSelectionGeneration: generation)
            offset = end
            if offset < file.count { XCTAssertEqual(progress.nextOffset, offset) }
            else { XCTAssertEqual(progress.nextFileIndex, 1) }
        }
        let status = try client.packageImportStatus(uploadId: upload,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)
        XCTAssertEqual(status.nextFileIndex, 1)
        let receipt = try client.commitPackageImport(uploadId: upload, expectedDigest: digest,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)
        XCTAssertEqual(receipt.includedBytes, file.count)
        XCTAssertEqual(receipt.provenance, "imported-package-untrusted")
        XCTAssertFalse(receipt.editableSourceIncluded)
        XCTAssertFalse(receipt.localBindingsImported)
        XCTAssertEqual(receipt.deploymentAuthority, "none")
        XCTAssertEqual(try WorkbenchPortablePackages(workspace: fixture.workspace).get(
            dashboardId: manifest.dashboardId, revision: manifest.revision).files["index.html"], file)
        let retried = try client.beginPackageImport(manifest: manifest, expectedDigest: digest,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)
        let retryUpload = try XCTUnwrap(retried.uploadId)
        offset = 0
        while offset < file.count {
            let end = min(offset + 64 * 1024, file.count)
            _ = try client.sendPackageImportChunk(uploadId: retryUpload,
                fileIndex: 0, offset: offset, bytes: file.subdata(in: offset..<end),
                expectedWorkspaceId: id, expectedSelectionGeneration: generation)
            offset = end
        }
        XCTAssertEqual(try client.commitPackageImport(uploadId: retryUpload, expectedDigest: digest,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation), receipt)
        let stale = try client.beginPackageImport(manifest: manifest, expectedDigest: digest,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)
        let staleUpload = try XCTUnwrap(stale.uploadId)
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("other-visible").path)
        XCTAssertThrowsError(try client.packageImportStatus(uploadId: staleUpload,
            expectedWorkspaceId: id, expectedSelectionGeneration: generation)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }
    func testBoundAuthoringMutationRejectsOtherClientsWorkspaceSwitch() throws {
        let fixture = try Fixture(mutationGate: {})
        defer { fixture.cleanup() }
        let firstPath = fixture.root.appendingPathComponent("first").path
        let firstWorkspace = try fixture.workspace.create(at: firstPath)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let author = WorkbenchBrokerClient(environment: fixture.environment)
        let switcher = WorkbenchBrokerClient(environment: fixture.environment)
        try author.connect(); try switcher.connect()
        defer { author.close(); switcher.close() }
        let captured = try author.workspaceStatus()
        XCTAssertEqual(captured.workspaceId, firstWorkspace.descriptor.workspaceId)
        let secondPath = fixture.root.appendingPathComponent("second").path
        let separateMachine = try WorkspaceStore(documents: FixtureDocuments(root: fixture.root),
            machineRootPath: fixture.root.appendingPathComponent("second-machine").path)
        _ = try separateMachine.create(at: secondPath)
        _ = try switcher.openWorkspace(path: secondPath)
        XCTAssertThrowsError(try author.performAuthoring(method: .projectCreate, params: [
            "schemaVersion": 1, "name": "Wrong workspace", "kind": "web",
            "expectedWorkspaceId": try XCTUnwrap(captured.workspaceId),
            "expectedSelectionGeneration": try XCTUnwrap(captured.selectionGeneration)
        ])) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        XCTAssertTrue(try fixture.workspace.inspect(at: firstPath).catalog.projects.isEmpty)
        XCTAssertTrue(try fixture.workspace.inspect(at: secondPath).catalog.projects.isEmpty)
    }

    func testSourceTextRouteRejectsAmbiguousGrammar() throws {
        let id = UUID().uuidString.lowercased()
        let valid: [String: Any] = ["schemaVersion": 1, "expectedWorkspaceId": id,
            "expectedSelectionGeneration": 1, "projectId": id, "path": "web/index.html"]
        XCTAssertEqual(try WorkbenchSourceTextRequest.parse(valid).projectId, id)
        var fractional = valid; fractional["schemaVersion"] = 1.5
        XCTAssertThrowsError(try WorkbenchSourceTextRequest.parse(fractional))
        var rogue = valid; rogue["absolutePath"] = "/private/tmp/elsewhere"
        XCTAssertThrowsError(try WorkbenchSourceTextRequest.parse(rogue))
        var omitted = valid; omitted.removeValue(forKey: "expectedSelectionGeneration")
        XCTAssertThrowsError(try WorkbenchSourceTextRequest.parse(omitted))
    }

    func testSocketSourceChunksBindEveryPageToSourceVersionAndSelection() throws {
        let fixture = try Fixture(mutationGate: {})
        defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let authoring = WorkbenchContainedAuthoring(workspace: fixture.workspace)
        let created = try authoring.create(name: "Chunk", kind: "web", trustedKitVersion: "1.0.0")
        let original = Data((0..<200_000).map { UInt8(65 + ($0 % 26)) })
        let patched = try authoring.patch(created.project.projectId,
            expectedSourceVersion: created.sourceVersion,
            changes: [.init(path: "data/large.txt", bytes: original)])
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let reader = WorkbenchBrokerClient(environment: fixture.environment)
        try reader.connect(); defer { reader.close() }
        let selected = try reader.workspaceStatus()
        let id = try XCTUnwrap(selected.workspaceId)
        let generation = try XCTUnwrap(selected.selectionGeneration)
        let direct = try fixture.domain.readSourceChunk(.init(expectedWorkspaceId: id,
            expectedSelectionGeneration: generation, projectId: created.project.projectId,
            path: "data/large.txt", expectedSourceVersion: patched.sourceVersion, offset: 0))
        XCTAssertEqual(direct.fileBytes, original.count)
        var assembled = Data(), offset = 0, pages = 0
        repeat {
            let page = try reader.sourceChunk(projectId: created.project.projectId,
                path: "data/large.txt", expectedSourceVersion: patched.sourceVersion,
                offset: offset, expectedWorkspaceId: id,
                expectedSelectionGeneration: generation)
            XCTAssertEqual(page.fileSHA256, DeploymentDigest.sha256Hex(original))
            XCTAssertEqual(page.fileBytes, original.count)
            assembled.append(try XCTUnwrap(Data(base64Encoded: page.bytesBase64)))
            offset = page.nextOffset; pages += 1
            if page.complete { break }
        } while pages < 8
        XCTAssertGreaterThan(pages, 1)
        XCTAssertEqual(assembled, original)
        XCTAssertEqual(offset, original.count)
        let changed = try authoring.patch(created.project.projectId,
            expectedSourceVersion: patched.sourceVersion,
            changes: [.init(path: "data/large.txt", bytes: Data("changed".utf8))])
        XCTAssertNotEqual(changed.sourceVersion, patched.sourceVersion)
        XCTAssertThrowsError(try reader.sourceChunk(projectId: created.project.projectId,
            path: "data/large.txt", expectedSourceVersion: patched.sourceVersion,
            offset: 65_536, expectedWorkspaceId: id,
            expectedSelectionGeneration: generation)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        try reader.connect()
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("second").path)
        XCTAssertThrowsError(try reader.sourceChunk(projectId: created.project.projectId,
            path: "data/large.txt", expectedSourceVersion: changed.sourceVersion,
            offset: 0, expectedWorkspaceId: id,
            expectedSelectionGeneration: generation)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }

    func testWorkspacePackagePagesKeepLargeHistoryReadableAndBindCursor() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let packages = WorkbenchPortablePackages(workspace: fixture.workspace)
        let file = Data("<html>Page</html>".utf8)
        for index in 0..<129 {
            var manifest = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
                dashboardId: "page-library", name: "Page \(index)",
                revision: "revision-\(index)", entrypoint: "index.html", sdkVersion: "1",
                target: ManifestTarget(profileId: "test", width: 800, height: 480,
                    scale: 1, orientation: "landscape"), connections: [],
                files: [ManifestFile(path: "index.html", bytes: file.count,
                    sha256: DeploymentDigest.sha256Hex(file))])
            manifest.digest = try DeploymentDigest.digest(for: manifest)
            _ = try packages.importVerified(.init(manifest: manifest, files: ["index.html": file]))
        }
        XCTAssertThrowsError(try packages.listPage(afterObjectId: nil,
            expectedInventoryHash: nil, deadline: ProcessInfo.processInfo.systemUptime - 1))
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let reader = WorkbenchBrokerClient(environment: fixture.environment)
        try reader.connect(); defer { reader.close() }
        let selected = try reader.workspaceStatus()
        let first = try reader.workspacePackagePage(in: selected)
        XCTAssertEqual(first.packages?.count, 128)
        XCTAssertEqual(first.hasMore, true)
        XCTAssertNotNil(first.nextCursor)
        XCTAssertEqual(first.ordering, "history-object-id-ascending")
        let second = try reader.workspacePackagePage(in: selected, cursor: first.nextCursor)
        XCTAssertEqual(second.packages?.count, 1)
        XCTAssertEqual(second.hasMore, false)
        XCTAssertNil(second.nextCursor)
        let complete = try reader.listWorkspacePackages(in: selected)
        XCTAssertEqual(complete.count, 129)
        XCTAssertEqual(Set(complete.map(\.revision)).count, 129)
        let bound: [String: Any] = ["schemaVersion": 1,
            "expectedWorkspaceId": try XCTUnwrap(selected.workspaceId),
            "expectedSelectionGeneration": try XCTUnwrap(selected.selectionGeneration)]
        let historyFirst = try reader.performAuthoring(method: .packageHistory, params: bound)
        XCTAssertEqual(historyFirst.packages?.count, 128)
        XCTAssertEqual(historyFirst.hasMore, true)
        XCTAssertEqual(historyFirst.ordering, "history-object-id-ascending")
        var nextBound = bound
        nextBound["cursor"] = try XCTUnwrap(historyFirst.nextCursor)
        let historySecond = try reader.performAuthoring(method: .packageHistory, params: nextBound)
        XCTAssertEqual(historySecond.packages?.count, 1)
        XCTAssertEqual(historySecond.hasMore, false)
        XCTAssertNil(historySecond.nextCursor)
        XCTAssertEqual(Set(((historyFirst.packages ?? []) + (historySecond.packages ?? [])).map(\.revision)).count, 129)
        var added = DashboardManifest(schemaVersion: PackageLimits.schemaMajor,
            dashboardId: "page-library", name: "Later", revision: "revision-129",
            entrypoint: "index.html", sdkVersion: "1",
            target: ManifestTarget(profileId: "test", width: 800, height: 480,
                scale: 1, orientation: "landscape"), connections: [],
            files: [ManifestFile(path: "index.html", bytes: file.count,
                sha256: DeploymentDigest.sha256Hex(file))])
        added.digest = try DeploymentDigest.digest(for: added)
        _ = try packages.importVerified(.init(manifest: added, files: ["index.html": file]))
        let stale = WorkbenchBrokerClient(environment: fixture.environment)
        try stale.connect(); defer { stale.close() }
        XCTAssertThrowsError(try stale.workspacePackagePage(in: selected, cursor: first.nextCursor)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
        let staleHistory = WorkbenchBrokerClient(environment: fixture.environment)
        try staleHistory.connect(); defer { staleHistory.close() }
        XCTAssertThrowsError(try staleHistory.performAuthoring(method: .packageHistory, params: nextBound)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }

    func testVerifiedGUIConnectionLeaseBlocksDrainUntilRelease() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let server = WorkbenchBrokerServer(environment: fixture.environment,
            domain: fixture.domain, guiVerifier: FixtureGUIVerifier())
        try server.start(); defer { server.stop() }
        let gui = WorkbenchBrokerClient(environment: fixture.environment)
        try gui.connect(); defer { gui.close() }
        let observer = WorkbenchBrokerClient(environment: fixture.environment)
        try observer.connect(); defer { observer.close() }
        XCTAssertFalse(try observer.serviceLifecycle().guiConsumersKnown)
        let registered = try gui.registerGUIConsumer()
        XCTAssertEqual(registered.leaseSeconds, 30)
        XCTAssertEqual(try observer.serviceLifecycle().guiConsumers, [registered.consumerId])
        XCTAssertEqual(try gui.renewGUIConsumer().consumerId, registered.consumerId)
        gui.close()
        let disconnectDeadline = Date().addingTimeInterval(2)
        while Date() < disconnectDeadline,
              try !observer.serviceLifecycle().guiConsumers.isEmpty {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(try observer.serviceLifecycle().guiConsumers, [])
        try gui.connect()
        let replacement = try gui.registerGUIConsumer()
        XCTAssertNotEqual(replacement.consumerId, registered.consumerId)
        let drained = DispatchSemaphore(value: 0)
        var drainResult: Swift.Result<WorkbenchServiceLifecycleResult, Error>?
        DispatchQueue.global().async {
            drainResult = Swift.Result { try observer.drainService() }
            drained.signal()
        }
        let inspector = WorkbenchBrokerClient(environment: fixture.environment)
        try inspector.connect(); defer { inspector.close() }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, try inspector.serviceLifecycle().state != "draining" {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(try inspector.serviceLifecycle().state, "draining")
        XCTAssertEqual(drained.wait(timeout: .now() + 0.02), .timedOut)
        XCTAssertEqual(try gui.releaseGUIConsumer().consumerId, replacement.consumerId)
        XCTAssertEqual(drained.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(try drainResult?.get().guiConsumersKnown ?? false)
        XCTAssertEqual(try drainResult?.get().guiConsumers, [])
    }

    func testWorkspacePackageReadsRejectClaimedRolesAndUnsafeMembers() throws {
        let base: [String: Any] = ["schemaVersion": 1, "expectedWorkspaceId": "workspace",
            "expectedSelectionGeneration": 1]
        XCTAssertThrowsError(try WorkbenchWorkspacePackageRequest.parse(.list,
            base.merging(["role": "gui"]) { _, new in new }))
        let package = base.merging(["dashboardId": "dashboard", "revision": "revision"]) { _, new in new }
        XCTAssertThrowsError(try WorkbenchWorkspacePackageRequest.parse(.file,
            package.merging(["path": "../secret", "offset": 0]) { _, new in new }))
        XCTAssertThrowsError(try WorkbenchWorkspacePackageRequest.parse(.file,
            package.merging(["path": "index.html", "offset": -1]) { _, new in new }))
        XCTAssertThrowsError(try WorkbenchWorkspacePackageRequest.parse(.get,
            package.merging(["expectedSelectionGeneration": true]) { _, new in new }))
        XCTAssertThrowsError(try WorkbenchGUIConsumerMethod.parse(.register,
            params: ["schemaVersion": 1, "role": "gui"]))
    }

    func testLifecycleCorrelatesSameRequestIDAcrossAuthenticatedSockets() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let fixture = try Fixture(dispatchObserver: { method in
            if method == .packageList {
                entered.signal()
                _ = release.wait(timeout: .now() + 5)
            }
        })
        defer { release.signal(); fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let first = try raw(fixture.environment); defer { Darwin.close(first) }
        let second = try raw(fixture.environment); defer { Darwin.close(second) }
        try authenticate(first, fixture.environment)
        try authenticate(second, fixture.environment)
        let request: [String: Any] = ["apiVersion": "1.0", "requestId": "same-request",
            "method": "package.list", "params": ["schemaVersion": 1]]
        try send(first, request, fixture.environment)
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        try send(second, request, fixture.environment)
        let observer = WorkbenchBrokerClient(environment: fixture.environment)
        try observer.connect(); defer { observer.close() }
        var active: [String] = []
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            active = try observer.serviceLifecycle().activeJobIDs
            if active.count == 2 { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(active.count, 2)
        XCTAssertEqual(Set(active).count, 2)
        XCTAssertTrue(active.allSatisfy { $0.hasPrefix("same-request.") })
        let drainClient = WorkbenchBrokerClient(environment: fixture.environment)
        try drainClient.connect(); defer { drainClient.close() }
        let drained = DispatchSemaphore(value: 0)
        var drainResult: Swift.Result<WorkbenchServiceLifecycleResult, Error>?
        DispatchQueue.global().async {
            drainResult = Swift.Result { try drainClient.drainService() }
            drained.signal()
        }
        let drainingDeadline = Date().addingTimeInterval(2)
        while Date() < drainingDeadline, try observer.serviceLifecycle().state != "draining" {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(try observer.serviceLifecycle().state, "draining")
        release.signal()
        release.signal()
        XCTAssertEqual(drained.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try drainResult?.get().interruptedJobIDs, active)
        XCTAssertEqual(try drainResult?.get().activeJobIDs, [])
    }

    func testDeviceControlIsClosedAndActivatesNativeOnlyOnExplicitCommand() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        try fixture.addDevice()
        let controller = fixture.controller
        let effects = fixture.effects
        let native = WorkbenchNativeComposition(activateOnStart: false, activate: { service in
            effects.activated()
            service.devices.attach(DomainFactory(effects: effects))
        }, deactivate: {
            effects.deactivated()
            controller.devices.attach(nil)
        })
        let domain = WorkbenchBrokerDomain(controller: controller, workspace: fixture.workspace, native: native,
            machineAuthorityPath: fixture.root.appendingPathComponent("machine/device-authority.json").path)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: domain)
        try server.start()
        defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try client.connect()
        defer { client.close() }
        _ = try client.health()
        _ = try client.listDevices()
        XCTAssertEqual(effects.activations, 0)
        XCTAssertThrowsError(try WorkbenchDeviceControlRequest.parse(method: .pairBegin,
            params: ["schemaVersion": 1, "deviceId": "device", "approved": true]))
        XCTAssertThrowsError(try WorkbenchDeviceControlRequest.parse(method: .settingsSet,
            params: ["schemaVersion": 1, "deviceId": "device", "expectedRevision": "rev",
                     "value": [:], "role": "gui"]))
        let endpoint = try client.addDevice(host: "127.0.0.1", port: 1234)
        XCTAssertEqual(endpoint.host, "127.0.0.1")
        XCTAssertEqual(effects.activations, 1)
        XCTAssertEqual(effects.helperResolutions, 0)
        let failed = WorkbenchBrokerClient(environment: fixture.environment)
        try failed.connect()
        XCTAssertThrowsError(try failed.deviceStatus("missing-device", refresh: true))
        failed.close()
        XCTAssertEqual(effects.deactivations, 0, "ordinary device errors must retain the native owner")
        _ = try client.discoverDevices()
        XCTAssertEqual(effects.activations, 1)
        XCTAssertTrue(controller.devices.transportAvailable)
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "current", kind: .http,
                method: .GET, path: "/api/current", idempotent: true, write: false)])
        XCTAssertThrowsError(try WorkbenchConnectionControlRequest.parse(method: .configure,
            params: ["schemaVersion": 1, "deviceId": "fixture-device", "dashboardId": "dash",
                "revision": "rev", "grant": try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)),
                "auth": ["authRef": "", "placement": "none"], "role": "gui"]))
        XCTAssertNoThrow(try WorkbenchConnectionControlRequest.parse(method: .configure,
            params: ["schemaVersion": 1, "deviceId": "fixture-device", "dashboardId": "dash",
                "revision": "rev", "grant": try JSONSerialization.jsonObject(with: JSONEncoder().encode(grant)),
                "auth": try JSONSerialization.jsonObject(with: JSONEncoder().encode(ConnectionAuthBinding(authRef: "", placement: .none)))]))
        let intent = try client.configureConnection(deviceId: "fixture-device", dashboardId: "dash",
            revision: "rev", grant: grant, auth: .init(authRef: "", placement: .none), secret: nil)
        XCTAssertEqual(intent.state, "pending")
        XCTAssertEqual(try client.connectionIntent(intent.intentId).declarationHash, intent.declarationHash)
        XCTAssertEqual(try client.listConnections(deviceId: "fixture-device"), [])
    }

    func testSocketCannotApproveAndFailedConfigurationDoesNotInstallCredential() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        try fixture.addDevice()
        let secrets = BrokerSecrets()
        let native = WorkbenchNativeComposition(activateOnStart: false, activate: { service in
            fixture.effects.activated(); service.devices.attach(DomainFactory(effects: fixture.effects))
        }, deactivate: {
            fixture.effects.deactivated(); fixture.controller.devices.attach(nil)
        })
        let domain = WorkbenchBrokerDomain(controller: fixture.controller, workspace: fixture.workspace,
            native: native, machineAuthorityPath: fixture.root.appendingPathComponent("machine/device-authority.json").path,
            secrets: secrets)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: domain)
        try server.start(); defer { server.stop() }
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "current", kind: .http,
                method: .GET, path: "/api/current", idempotent: true, write: false)])
        let auth = ConnectionAuthBinding(authRef: "", placement: .bearer)
        let missing = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try missing.connect()
        XCTAssertThrowsError(try missing.configureConnection(deviceId: "not-paired", dashboardId: "dash",
            revision: "rev", grant: grant, auth: auth, secret: Data("canary-secret".utf8)))
        missing.close()
        XCTAssertEqual(secrets.installCalls, 0)
        XCTAssertTrue(secrets.values.isEmpty)

        let configured = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try configured.connect()
        let intent = try configured.configureConnection(deviceId: "fixture-device", dashboardId: "dash",
            revision: "rev", grant: grant, auth: auth, secret: Data("canary-secret".utf8))
        configured.close()
        XCTAssertEqual(intent.state, "pending")
        XCTAssertEqual(secrets.installCalls, 1)
        XCTAssertEqual(secrets.values.count, 1)
        let approval = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try approval.connect()
        XCTAssertThrowsError(try approval.resolveConnectionIntent(intent.intentId, approve: true)) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .confirmationRequired)
        }
        approval.close()
        XCTAssertEqual(secrets.values.count, 1, "rejected socket approval must not provision or discard consent")
        let denial = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try denial.connect()
        XCTAssertTrue(try denial.resolveConnectionIntent(intent.intentId, approve: false).denied == true)
        XCTAssertEqual(try denial.connectionIntent(intent.intentId).state, "denied")
        denial.close()
        XCTAssertTrue(secrets.values.isEmpty, "denial removes only the staged credential")

        secrets.failAfterInstall = true; secrets.removeLocked = true
        var failingGrant = grant; failingGrant.id = UUID()
        let failing = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try failing.connect()
        XCTAssertThrowsError(try failing.configureConnection(deviceId: "fixture-device", dashboardId: "dash",
            revision: "rev", grant: failingGrant, auth: auth, secret: Data("canary-secret".utf8))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .credentialCleanupRequired)
            XCTAssertFalse(String(describing: $0).contains("canary-secret"))
        }
        failing.close()
        XCTAssertEqual(secrets.values.count, 1)
        let authority = try WorkbenchLocalAuthorityStore(
            path: fixture.root.appendingPathComponent("machine/device-authority.json").path)
        let failedIntent = try XCTUnwrap(authority.read().intents.values.first(where: {
            $0.grant.id == failingGrant.id
        }))
        XCTAssertEqual(failedIntent.state, .rejected)
        secrets.failAfterInstall = false; secrets.removeLocked = false
        let recovery = WorkbenchBrokerClient(environment: fixture.environment, credentialScope: .localReview)
        try recovery.connect()
        XCTAssertEqual(try recovery.connectionIntent(failedIntent.intentId).state, "rejected")
        recovery.close()
        XCTAssertTrue(secrets.values.isEmpty)
    }

    func testTimedOutConfigurationRejectsIntentAndRemovesStagedCredential() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        try fixture.addDevice()
        let secrets = BrokerSecrets(); secrets.installDelay = 0.35
        let native = WorkbenchNativeComposition(activateOnStart: false, activate: { service in
            service.devices.attach(DomainFactory(effects: fixture.effects))
        }, deactivate: { fixture.controller.devices.attach(nil) })
        let domain = WorkbenchBrokerDomain(controller: fixture.controller, workspace: fixture.workspace,
            native: native, dispatchObserver: nil, localReadTimeout: 0.2,
            machineAuthorityPath: fixture.root.appendingPathComponent("machine/device-authority.json").path,
            secrets: secrets)
        try domain.start(); defer { domain.stop() }
        let grant = ConnectionGrant(schemaVersion: 1, id: UUID(), alias: "weather",
            origin: "https://example.local", transport: .http, authRef: "", lan: true,
            allowInsecureHTTP: false, operations: [.init(name: "current", kind: .http,
                method: .GET, path: "/api/current", idempotent: true, write: false)])
        let request = WorkbenchConnectionControlRequest.configure("fixture-device", "dash", "rev",
            grant, ConnectionAuthBinding(authRef: "", placement: .bearer), Data("canary-secret".utf8))
        XCTAssertThrowsError(try domain.performConnection(request))
        XCTAssertEqual(secrets.installCalls, 1)
        XCTAssertTrue(secrets.values.isEmpty)
        let state = try WorkbenchLocalAuthorityStore(
            path: fixture.root.appendingPathComponent("machine/device-authority.json").path).read()
        let intent = try XCTUnwrap(state.intents.values.first(where: { $0.grant.id == grant.id }))
        XCTAssertEqual(intent.state, .denied)
        XCTAssertEqual(intent.managedSecret, false)
    }

    func testReadWireAcceptsOnlySafeNonnegativeIntegerVersionsAndCounts() throws {
        for number in ["0", "1", "9007199254740991"] {
            XCTAssertNoThrow(try WorkbenchWireJSON.object(Data("{\"count\":\(number)}".utf8)))
        }
        for number in ["01", "1.0", "1e0", "-1", "9007199254740992", "184467440737095516160"] {
            XCTAssertThrowsError(try WorkbenchWireJSON.object(Data("{\"count\":\(number)}".utf8)))
        }
    }

    func testPartialNativeActivationIsCleanedBeforeBrokerCanRestart() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let native = WorkbenchNativeComposition(activate: { controller in
            fixture.effects.activated()
            controller.devices.attach(DomainFactory(effects: fixture.effects))
            throw WorkbenchIPCError(.unavailable)
        }, deactivate: {
            fixture.effects.deactivated()
            fixture.controller.devices.attach(nil)
        })
        let failedDomain = WorkbenchBrokerDomain(controller: fixture.controller, native: native)
        let failedServer = WorkbenchBrokerServer(environment: fixture.environment, domain: failedDomain)
        XCTAssertThrowsError(try failedServer.start())
        XCTAssertEqual(fixture.effects.activations, 1)
        XCTAssertEqual(fixture.effects.deactivations, 1)
        XCTAssertFalse(fixture.controller.devices.transportAvailable)
        let replacement = WorkbenchBrokerServer(environment: fixture.environment)
        XCTAssertEqual(try replacement.start().supportedMethods, WorkbenchMethodRegistry.supportedMethods)
        replacement.stop()
    }

    func testLazyNativeActivationFailureCleansPartialAttachAndCanRetry() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        var failOnce = true
        let native = WorkbenchNativeComposition(activateOnStart: false, activate: { controller in
            fixture.effects.activated()
            controller.devices.attach(DomainFactory(effects: fixture.effects))
            if failOnce { failOnce = false; throw ControllerError.deviceOffline("fake partial activation") }
        }, deactivate: {
            fixture.effects.deactivated(); fixture.controller.devices.attach(nil)
        })
        let domain = WorkbenchBrokerDomain(controller: fixture.controller, native: native)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: domain)
        try server.start(); defer { server.stop() }
        let first = WorkbenchBrokerClient(environment: fixture.environment)
        try first.connect()
        XCTAssertThrowsError(try first.discoverDevices())
        first.close()
        XCTAssertEqual(fixture.effects.activations, 1)
        XCTAssertEqual(fixture.effects.deactivations, 1)
        XCTAssertFalse(fixture.controller.devices.transportAvailable)
        let second = WorkbenchBrokerClient(environment: fixture.environment)
        try second.connect()
        _ = try second.discoverDevices()
        second.close()
        XCTAssertEqual(fixture.effects.activations, 2)
        XCTAssertTrue(fixture.controller.devices.transportAvailable)
    }

    func testTwoSocketClientsShareOneReadOnlyDomainAndTruthfulCapabilities() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspace = try fixture.workspace.create(at: fixture.root.appendingPathComponent("visible").path)
        let source = try WorkbenchContainedAuthoring(workspace: fixture.workspace).create(
            name: "Broker source", kind: "web", trustedKitVersion: "1.0.0")
        let package = try fixture.controller.updateDashboard(arguments: .object([
            "name": .string("Fixture"),
            "files": .array([.object(["path": .string("index.html"), "text": .string("<p>Fixture</p>")])])
        ]))
        try fixture.addDevice()
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        let started = try server.start()
        defer { server.stop() }
        let first = WorkbenchBrokerClient(environment: fixture.environment)
        let second = WorkbenchBrokerClient(environment: fixture.environment)
        try first.connect(); try second.connect()
        defer { first.close(); second.close() }
        let unverified = WorkbenchBrokerClient(environment: fixture.environment)
        try unverified.connect()
        XCTAssertThrowsError(try unverified.registerGUIConsumer()) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .incompatibleOwner)
        }
        unverified.close()
        XCTAssertEqual(fixture.effects.activations, 1)
        XCTAssertEqual(started.workspaceState, "selected")
        XCTAssertEqual(started.devices, "read-only")
        XCTAssertEqual(started.build, "unavailable")
        XCTAssertEqual(started.screenshots, "unavailable")
        XCTAssertEqual(started.supportedMethods,
            WorkbenchMethodRegistry.supportedMethods + WorkbenchDomainMethodRegistry.availableReadMethods
                + WorkbenchDomainMethodRegistry.availableWorkspaceMethods
                + WorkbenchDeviceControlMethod.advertisedCases.map(\.rawValue)
                + WorkbenchConnectionControlMethod.allCases.map(\.rawValue)
                + WorkbenchAuthoringRecoveryMethod.advertisedCases.map(\.rawValue)
                + [WorkbenchSourceTextRequest.method, WorkbenchSourceChunkRequest.method]
                + WorkbenchPackageImportMethod.allCases.map(\.rawValue)
                + WorkbenchLocalReviewMethod.allCases.map(\.rawValue)
                + WorkbenchHomeAssistantMethod.allCases.map(\.rawValue)
                + [WorkbenchWorkspaceOperationStatus.method,
                   WorkbenchWorkspaceOperationStatus.cancelMethod,
                   WorkbenchWorkspaceOperationList.method,
                   WorkbenchOperationInventory.listMethod,
                   WorkbenchOperationInventory.showMethod,
                   WorkbenchOperationInventory.cancelMethod,
                   WorkbenchRetainedDeploymentEvidenceRead.method,
                   WorkbenchDeviceLogRead.method,
                   WorkbenchNativeDoctorRead.method]
                + [WorkbenchToolchainRequirementsRead.method,
                   WorkbenchToolchainInstallResult.method]
                + WorkbenchWorkspacePackageMethod.allCases.map(\.rawValue)
                + WorkbenchScreenMutationMethod.allCases.map(\.rawValue)
                + WorkbenchDeploymentMethod.allCases.map(\.rawValue)
                + WorkbenchGUIConsumerMethod.allCases.map(\.rawValue))
        XCTAssertEqual(try first.capabilities(), try second.capabilities())
        XCTAssertEqual(try first.workspaceStatus().workspaceId, workspace.descriptor.workspaceId)
        XCTAssertEqual(try second.workspaceStatus().path, workspace.path)
        XCTAssertEqual(try first.workspaceCoverage().containedProjectIds, [source.project.projectId])
        XCTAssertEqual(try first.workspaceCoverage(validate: true).valid, true)
        XCTAssertEqual(try first.listProjects().map(\.projectId), [source.project.projectId])
        XCTAssertEqual(try second.getProject(source.project.projectId).dashboardId, source.project.dashboardId)
        XCTAssertEqual(try second.projectPath(source.project.projectId), source.path)
        XCTAssertEqual(try second.projectVersions(source.project.projectId).map(\.sourceVersion), [source.sourceVersion])
        let sourceSelection = try first.workspaceStatus()
        let sourceText = try first.sourceText(projectId: source.project.projectId,
            path: "web/index.html", expectedWorkspaceId: try XCTUnwrap(sourceSelection.workspaceId),
            expectedSelectionGeneration: try XCTUnwrap(sourceSelection.selectionGeneration))
        XCTAssertEqual(sourceText.sourceVersion, source.sourceVersion)
        XCTAssertFalse(sourceText.text.isEmpty)
        XCTAssertEqual(try first.listPackages().map(\.dashboardId), [package.manifest.dashboardId])
        XCTAssertEqual(try second.requestMCPRead(tool: "list_dashboards", arguments: [:]).packages?.map(\.dashboardId), [package.manifest.dashboardId])
        XCTAssertThrowsError(try second.requestMCPRead(tool: "system.execute", arguments: ["method":"package.list"]))
        let detail = try second.validatePackage(dashboardId: package.manifest.dashboardId, revision: package.manifest.revision)
        XCTAssertEqual(detail.digest, package.manifest.digest)
        XCTAssertEqual(detail.integrity, "verified-local-bytes-no-provenance")
        XCTAssertEqual(try first.getPackage(dashboardId: package.manifest.dashboardId).revision, detail.revision)
        XCTAssertEqual(try first.listDevices().map(\.deviceId), ["fixture-device"])
        let device = try second.getDevice(deviceId: "fixture-device")
        XCTAssertTrue(device.ownerMatchesCurrent)
        XCTAssertEqual(device.reachability, "not-probed")
        XCTAssertEqual(fixture.effects.activations, 1)
        XCTAssertEqual(fixture.effects.linkCreations, 0)
        XCTAssertEqual(fixture.effects.helperResolutions, 0)
        let replacementPath = fixture.root.appendingPathComponent("replacement").path
        let separateMachine = try WorkspaceStore(documents: FixtureDocuments(root: fixture.root),
            machineRootPath: fixture.root.appendingPathComponent("second-machine").path)
        _ = try separateMachine.create(at: replacementPath)
        _ = try second.openWorkspace(path: replacementPath)
        XCTAssertThrowsError(try first.sourceText(projectId: source.project.projectId,
            path: "web/index.html", expectedWorkspaceId: try XCTUnwrap(sourceSelection.workspaceId),
            expectedSelectionGeneration: try XCTUnwrap(sourceSelection.selectionGeneration))) {
            XCTAssertEqual(($0 as? WorkbenchIPCError)?.code, .workspaceConflict)
        }
    }

    func testConcurrentClientsSerializeDispatchAndStopDrainsNativeOwner() throws {
        let fixture = try Fixture(observeDispatch: true)
        defer { fixture.cleanup() }
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start()
        defer { server.stop() }
        let group = DispatchGroup()
        let failures = LockedFailures()
        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let client = WorkbenchBrokerClient(environment: fixture.environment)
                do { try client.connect(); _ = try client.listPackages(); client.close() }
                catch { failures.append(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(failures.values.isEmpty, "all clients should share the same available domain: \(failures.values)")
        XCTAssertEqual(fixture.effects.maximumConcurrentDispatches, 1)
        XCTAssertEqual(fixture.effects.activations, 1)
        server.stop()
        XCTAssertEqual(fixture.effects.deactivations, 1)
        XCTAssertFalse(fixture.controller.devices.transportAvailable)
    }

    func testInvalidUnknownPrivilegedAndIncompatibleCallsFailBeforeDomainDispatch() throws {
        let fixture = try Fixture(observeDispatch: true)
        defer { fixture.cleanup() }
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let examples: [([String: Any], WorkbenchIPCErrorCode)] = [
            (["apiVersion":"1.0", "requestId":"r", "method":"package.list", "params":["schemaVersion":2]], .unsupportedVersion),
            (["apiVersion":"1.0", "requestId":"r", "method":"package.list", "params":["schemaVersion":true]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"package.list", "params":["schemaVersion":1,"approved":true]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"device.get", "params":["schemaVersion":1,"deviceId":"fixture","probe":true]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"package.get", "params":["schemaVersion":1,"dashboardId":"../escape"]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"project.get", "params":["schemaVersion":1,"projectId":"../escape"]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"project.path", "params":["schemaVersion":1,"projectId":"fixture","approved":true]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"connection.configure", "params":["schemaVersion":1]], .methodNotFound),
            (["apiVersion":"1.0", "requestId":"r", "method":"connection.reviewBegin", "params":["schemaVersion":1,"intentId":"fake","role":"gui"]], .methodNotFound),
            (["apiVersion":"1.0", "requestId":"r", "method":"connection.reviewConfirm", "params":["schemaVersion":1,"reviewHandle":"fake","confirm":true]], .methodNotFound),
            (["apiVersion":"1.0", "requestId":"r", "method":"approval.resolve", "params":["schemaVersion":1]], .methodNotFound),
            (["apiVersion":"1.0", "requestId":"r", "method":"deployment.apply", "params":["schemaVersion":1]], .invalidRequest),
            (["apiVersion":"1.0", "requestId":"r", "method":"system.execute", "params":[:]], .methodNotFound),
            (["apiVersion":"2.0", "requestId":"r", "method":"package.list", "params":["schemaVersion":1]], .unsupportedVersion),
            (["apiVersion":"1.0", "requestId":"r", "method":"package.list", "params":["schemaVersion":1], "role":"gui"], .invalidRequest)
        ]
        for (request, expected) in examples {
            let fd = try raw(fixture.environment)
            defer { Darwin.close(fd) }
            try authenticate(fd, fixture.environment)
            try send(fd, request, fixture.environment)
            let response = try read(fd, fixture.environment)
            XCTAssertEqual(response.error?.code, expected, "\(request["method"] ?? "unknown")")
        }
        XCTAssertEqual(fixture.effects.dispatches, 0)
        XCTAssertEqual(fixture.effects.linkCreations, 0)
        XCTAssertEqual(fixture.effects.helperResolutions, 0)
    }

    func testSharedMCPPolicyHasNoPrivilegedOrGenericForwardingRoute() throws {
        XCTAssertEqual(try WorkbenchMCPReadPolicy.route(tool: "get_workspace", arguments: [:]).method, "workspace.status")
        XCTAssertEqual(try WorkbenchMCPReadPolicy.route(tool: "get_device", arguments: ["deviceId":"fixture", "probe":false]).method, "device.get")
        for tool in ["connection.configure", "approval.resolve", "system.execute", "deployment.apply", "configure_connection", "resolve_approval"] {
            XCTAssertThrowsError(try WorkbenchMCPReadPolicy.route(tool: tool, arguments: [:]))
        }
        let invalidArguments: [[String: Any]] = [
            ["deviceId":"fixture", "probe":true],
            ["deviceId":"fixture", "role":"terminal"],
            ["deviceId":"fixture", "consentSource":"gui"],
            ["deviceId":"fixture", "schemaVersion":1],
            ["deviceId":"fixture", "secret":"token"]
        ]
        for arguments in invalidArguments {
            XCTAssertThrowsError(try WorkbenchMCPReadPolicy.route(tool: "get_device", arguments: arguments))
        }
    }

    func testOversizedStoredMetadataReturnsBoundedErrorWithoutTransport() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.addDevice(name: String(repeating: "x", count: 5000))
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: fixture.environment)
        try client.connect(); defer { client.close() }
        XCTAssertThrowsError(try client.listDevices()) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .resourceLimit)
        }
        XCTAssertEqual(fixture.effects.linkCreations, 0)
    }

    func testMalformedLegacySizesReturnErrorsAndKeepHealthAlive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let record = try fixture.controller.updateDashboard(arguments: .object([
            "name": .string("Corruptible fixture"),
            "files": .array([
                .object(["path": .string("index.html"), "text": .string("<p>ok</p>")]),
                .object(["path": .string("second.js"), "text": .string("ok")])
            ])
        ]))
        var manifest = record.manifest
        manifest.files[0].bytes = Int.max
        manifest.files[1].bytes = 1
        try JSONEncoder().encode(manifest).write(to: record.packageDirectory.appendingPathComponent("manifest.json"), options: .atomic)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start(); defer { server.stop() }
        let client = WorkbenchBrokerClient(environment: fixture.environment)
        try client.connect()
        XCTAssertThrowsError(try client.getPackage(dashboardId: manifest.dashboardId)) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .unavailable)
        }
        let another = WorkbenchBrokerClient(environment: fixture.environment)
        try another.connect()
        XCTAssertThrowsError(try another.validatePackage(dashboardId: manifest.dashboardId)) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .unavailable)
        }
        let health = WorkbenchBrokerClient(environment: fixture.environment)
        try health.connect(); defer { health.close() }
        XCTAssertEqual(try health.health().devices, "read-only")
    }

    func testHeldLegacyLockDeadlineDisconnectDrainAndRestart() throws {
        let fixture = try Fixture(observeDispatch: true, localReadTimeout: 0.25)
        defer { fixture.cleanup() }
        let holder = open(fixture.controller.store.root.appendingPathComponent("lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { if holder >= 0 { _ = flock(holder, LOCK_UN); close(holder) } }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start()
        let client = WorkbenchBrokerClient(environment: fixture.environment)
        try client.connect()
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try client.listPackages()) { error in
            XCTAssertEqual((error as? WorkbenchIPCError)?.code, .unavailable)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 1.5)
        let health = WorkbenchBrokerClient(environment: fixture.environment)
        try health.connect()
        XCTAssertEqual(try health.health().devices, "read-only")
        health.close()

        let fd = try raw(fixture.environment)
        try authenticate(fd, fixture.environment)
        try send(fd, ["apiVersion":"1.0", "requestId":"blocked", "method":"package.list",
                      "params":["schemaVersion":1]], fixture.environment)
        let waitUntil = ProcessInfo.processInfo.systemUptime + 1
        while fixture.effects.dispatches < 2 && ProcessInfo.processInfo.systemUptime < waitUntil {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertGreaterThanOrEqual(fixture.effects.dispatches, 2)
        close(fd)
        let afterDisconnect = WorkbenchBrokerClient(environment: fixture.environment)
        let healthBegin = ProcessInfo.processInfo.systemUptime
        try afterDisconnect.connect()
        XCTAssertEqual(try afterDisconnect.health().devices, "read-only")
        afterDisconnect.close()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - healthBegin, 1)
        let stopBegin = ProcessInfo.processInfo.systemUptime
        server.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stopBegin, 1)
        XCTAssertEqual(fixture.effects.deactivations, 1)
        XCTAssertFalse(fixture.controller.devices.transportAvailable)

        XCTAssertEqual(flock(holder, LOCK_UN), 0)
        let restarted = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try restarted.start(); defer { restarted.stop() }
        let normal = WorkbenchBrokerClient(environment: fixture.environment)
        try normal.connect(); defer { normal.close() }
        XCTAssertTrue(try normal.listPackages().isEmpty)
    }

    func testSelectedWorkspaceLockCannotBlockStatusHealthOrStop() throws {
        let fixture = try Fixture(observeDispatch: true, localReadTimeout: 0.2)
        defer { fixture.cleanup() }
        _ = try fixture.workspace.create(at: fixture.root.appendingPathComponent("selected").path)
        let server = WorkbenchBrokerServer(environment: fixture.environment, domain: fixture.domain)
        try server.start()
        let statusClient = WorkbenchBrokerClient(environment: fixture.environment)
        let healthClient = WorkbenchBrokerClient(environment: fixture.environment)
        try statusClient.connect(); try healthClient.connect()
        defer { statusClient.close(); healthClient.close() }
        let holder = open(fixture.root.appendingPathComponent("machine/.screenpunk.lock").path, O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(holder, 0)
        defer { if holder >= 0 { _ = flock(holder, LOCK_UN); close(holder) } }
        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let fallback = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            _ = flock(holder, LOCK_UN); fallback.signal()
        }
        let statusDone = DispatchGroup()
        let statusResult = LockedReadCode()
        statusDone.enter()
        DispatchQueue.global().async {
            defer { statusDone.leave() }
            do { _ = try statusClient.workspaceStatus(); statusResult.record(nil) }
            catch { statusResult.record((error as? WorkbenchIPCError)?.code) }
        }
        let dispatchDeadline = ProcessInfo.processInfo.systemUptime + 1
        while fixture.effects.dispatches < 1 && ProcessInfo.processInfo.systemUptime < dispatchDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertGreaterThanOrEqual(fixture.effects.dispatches, 1)
        let healthBegin = ProcessInfo.processInfo.systemUptime
        let blockedHealth = try healthClient.health()
        XCTAssertEqual(blockedHealth.devices, "read-only")
        XCTAssertEqual(blockedHealth.workspaceState, "unavailable")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - healthBegin, 0.5)
        XCTAssertEqual(statusDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(statusResult.code, .unavailable)
        XCTAssertEqual(fallback.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(try healthClient.health().workspaceState, "selected")
        XCTAssertEqual(try fixture.workspace.current()?.path, fixture.root.appendingPathComponent("selected").path)

        XCTAssertEqual(flock(holder, LOCK_EX | LOCK_NB), 0)
        let stopFallback = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            _ = flock(holder, LOCK_UN); stopFallback.signal()
        }
        let fd = try raw(fixture.environment)
        try authenticate(fd, fixture.environment)
        let nextDispatch = fixture.effects.dispatches + 1
        try send(fd, ["apiVersion":"1.0", "requestId":"blocked", "method":"workspace.status",
                      "params":["schemaVersion":1]], fixture.environment)
        let nextDeadline = ProcessInfo.processInfo.systemUptime + 1
        while fixture.effects.dispatches < nextDispatch && ProcessInfo.processInfo.systemUptime < nextDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        close(fd)
        let stopBegin = ProcessInfo.processInfo.systemUptime
        server.stop()
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - stopBegin, 0.5)
        XCTAssertEqual(fixture.effects.deactivations, 1)
        XCTAssertFalse(fixture.controller.devices.transportAvailable)
        XCTAssertEqual(stopFallback.wait(timeout: .now() + 2), .success)
    }

    private func raw(_ env: WorkbenchBrokerEnvironment) throws -> Int32 {
        let fd = try WorkbenchSocket.make()
        let status = try WorkbenchSocket.address(env.runtimeDirectory.appendingPathComponent("broker.sock").path) {
            Darwin.connect(fd, $0, $1)
        }
        guard status == 0 || errno == EINPROGRESS else { Darwin.close(fd); throw WorkbenchIPCError(.unavailable) }
        if status != 0 { try WorkbenchSocket.wait(fd, events: Int16(POLLOUT), deadline: env.clock.now() + 2, clock: env.clock) }
        return fd
    }
    private func send(_ fd: Int32, _ object: [String: Any], _ env: WorkbenchBrokerEnvironment) throws {
        try WorkbenchSocket.writeFrame(fd, bytes: JSONSerialization.data(withJSONObject: object), environment: env)
    }
    private func read(_ fd: Int32, _ env: WorkbenchBrokerEnvironment) throws -> WorkbenchWireResponse {
        try JSONDecoder().decode(WorkbenchWireResponse.self, from: WorkbenchSocket.readFrame(fd, environment: env))
    }
    private func authenticate(_ fd: Int32, _ env: WorkbenchBrokerEnvironment) throws {
        let directory = try WorkbenchRuntimeDirectory(environment: env, create: false)
        try send(fd, ["apiVersion":"1.0", "instanceId":directory.locator().instanceId,
                      "token":directory.read("broker.token", maxBytes: 32).base64EncodedString()], env)
        XCTAssertTrue(try read(fd, env).ok)
        try send(fd, ["apiVersion":"1.0", "requestId":"hello", "method":"system.hello", "params":[:]], env)
        XCTAssertTrue(try read(fd, env).ok)
    }
}

private struct FixtureGUIVerifier: WorkbenchGUIConsumerVerifier {
    func verifyConnectedPeer(socket: Int32) -> Bool { socket >= 0 }
}

private final class Fixture {
    let root: URL
    let environment: WorkbenchBrokerEnvironment
    let workspace: WorkspaceStore
    let controller: ControllerService
    let domain: WorkbenchBrokerDomain
    let effects = DomainEffects()

    init(observeDispatch: Bool = false, localReadTimeout: TimeInterval = 15,
         dispatchObserver: ((WorkbenchReadMethod) -> Void)? = nil,
         mutationGate: (() throws -> Void)? = nil) throws {
        root = URL(fileURLWithPath: "/private/tmp/sp-domain-" + UUID().uuidString.prefix(12))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root.appendingPathComponent("machine"), withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        environment = try WorkbenchBrokerEnvironment(runtimeDirectory: root.appendingPathComponent("runtime"))
        workspace = try WorkspaceStore(documents: FixtureDocuments(root: root), machineRootPath: root.appendingPathComponent("machine").path)
        let effects = self.effects
        let createdController = try ControllerService.bootstrap(root: root.appendingPathComponent("legacy"),
            deviceDirectoryURL: root.appendingPathComponent("machine/devices.json"),
            rendererFactory: { effects.helperResolution() })
        controller = createdController
        let native = WorkbenchNativeComposition(activate: { controller in
            effects.activated()
            controller.devices.attach(DomainFactory(effects: effects))
        }, deactivate: {
            effects.deactivated()
            createdController.devices.attach(nil)
        })
        domain = WorkbenchBrokerDomain(controller: controller, workspace: workspace, native: native,
            dispatchObserver: dispatchObserver ?? (observeDispatch ? { _ in
                effects.enterDispatch(); Thread.sleep(forTimeInterval: 0.01); effects.exitDispatch()
            } : nil),
            localReadTimeout: localReadTimeout, mutationGate: mutationGate)
    }

    func addDevice(name: String = "Fixture device") throws {
        let owner = PairingIdentity(role: .controller, publicKey: Array(repeating: 7, count: 32))
        let device = PairedDevice(profile: DeviceProfile(deviceId: "fixture-device", name: name), owner: owner, reachable: false)
        try controller.devices.directory.upsert(PairedDeviceRecord(device: device, host: "127.0.0.1", port: 1234,
            devicePinHex: PeerPin.hex(Array(repeating: 8, count: 32)), pairedAt: Date()))
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

private struct FixtureDocuments: WorkspaceDocumentsResolver {
    let root: URL
    func documentsDirectory() throws -> URL { root.appendingPathComponent("Documents") }
}
private struct DomainFactory: DeviceLinkFactory {
    let effects: DomainEffects
    var controllerIdentity: PairingIdentity { PairingIdentity(role: .controller, publicKey: Array(repeating: 7, count: 32)) }
    func makeLink() throws -> DeviceLink { effects.linkCreation(); throw ControllerError.deviceOffline("fake transport") }
}
private final class BrokerSecrets: WorkbenchSecretProvider {
    var values: [String: Data] = [:]
    var installCalls = 0
    var failAfterInstall = false
    var removeLocked = false
    var installDelay: TimeInterval = 0
    func install(_ secret: Data, for authRef: String) throws {
        if installDelay > 0 { Thread.sleep(forTimeInterval: installDelay) }
        installCalls += 1; values[authRef] = secret
        if failAfterInstall { throw ConnectionFailure.permissionRequired }
    }
    func load(authRef: String) throws -> Data {
        guard let value = values[authRef] else { throw ConnectionFailure.permissionRequired }
        return value
    }
    func remove(authRef: String) throws {
        if removeLocked { throw ConnectionFailure.permissionRequired }
        values[authRef] = nil
    }
}
private final class DomainEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0, links = 0, helpers = 0, active = 0, maximum = 0, calls = 0
    var activations: Int { lock.lock(); defer { lock.unlock() }; return starts }
    var deactivations: Int { lock.lock(); defer { lock.unlock() }; return stops }
    var linkCreations: Int { lock.lock(); defer { lock.unlock() }; return links }
    var helperResolutions: Int { lock.lock(); defer { lock.unlock() }; return helpers }
    var maximumConcurrentDispatches: Int { lock.lock(); defer { lock.unlock() }; return maximum }
    var dispatches: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func activated() { lock.lock(); starts += 1; lock.unlock() }
    func deactivated() { lock.lock(); stops += 1; lock.unlock() }
    func linkCreation() { lock.lock(); links += 1; lock.unlock() }
    func helperResolution() -> PreviewRenderer? { lock.lock(); helpers += 1; lock.unlock(); return nil }
    func enterDispatch() { lock.lock(); active += 1; calls += 1; maximum = max(maximum, active); lock.unlock() }
    func exitDispatch() { lock.lock(); active -= 1; lock.unlock() }
}
private final class LockedFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [String] = []
    var values: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func append(_ error: Error) { lock.lock(); errors.append(String(describing: error)); lock.unlock() }
}
private final class LockedReadCode: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: WorkbenchIPCErrorCode?
    var code: WorkbenchIPCErrorCode? { lock.lock(); defer { lock.unlock() }; return stored }
    func record(_ code: WorkbenchIPCErrorCode?) { lock.lock(); stored = code; lock.unlock() }
}
#endif
