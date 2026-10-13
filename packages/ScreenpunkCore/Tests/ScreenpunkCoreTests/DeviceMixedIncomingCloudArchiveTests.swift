import Foundation
import XCTest
import CNativeArchive
#if canImport(CryptoKit)
import CryptoKit
#endif
@_spi(NativeInstallation) @_spi(ManagedRender) @testable import ScreenpunkCore

final class DeviceMixedIncomingCloudArchiveTests:XCTestCase {
    #if canImport(CryptoKit) && (os(iOS) || os(macOS))
    private func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    private func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)}
    private struct Fixture {let files:[(String,Data)],expected:DevicePackageExpectation,manifest:Data}
    private func fixture()throws->Fixture {
        let html=Data("<html><body>actual bounded ZIP fixture</body></html>".utf8)
        var manifest=DashboardManifest(schemaVersion:1,dashboardId:UUID().uuidString.lowercased(),name:"ZIP fixture",revision:UUID().uuidString.lowercased(),entrypoint:"index.html",sdkVersion:"1",target:.init(profileId:"profile",width:390,height:844,scale:3,orientation:"portrait"),connections:[],files:[.init(path:"index.html",bytes:html.count,sha256:hash(html))])
        manifest.digest=hash(try encode(manifest));let raw=try encode(manifest)
        let revision=StoredRevision(revision:manifest.revision,dashboardId:manifest.dashboardId,name:manifest.name,digest:manifest.digest!,orientation:.portrait,width:390,height:844)
        return .init(files:[("manifest.json",raw),("index.html",html)],expected:.init(revision:revision,target:.init(deviceId:"fixture",name:"Fixture"),profileID:"profile"),manifest:raw)
    }
    private func crc(_ bytes:Data)->UInt32 {
        var value:UInt32=0xffffffff
        for b in bytes {value ^= UInt32(b);for _ in 0..<8{value=value & 1 == 1 ? (value >> 1) ^ 0xedb88320:value >> 1}}
        return value ^ 0xffffffff
    }
    private func word(_ value:UInt16)->Data {Data([UInt8(truncatingIfNeeded:value),UInt8(truncatingIfNeeded:value >> 8)])}
    private func long(_ value:UInt32)->Data {Data([UInt8(truncatingIfNeeded:value),UInt8(truncatingIfNeeded:value >> 8),UInt8(truncatingIfNeeded:value >> 16),UInt8(truncatingIfNeeded:value >> 24)])}
    /// Genuine raw DEFLATE stored block inside ZIP method8. Uses no external dependency or
    /// production decompressor to construct the fixture; CRC is independent test arithmetic.
    private func deflated(_ bytes:Data)->Data {
        precondition(bytes.count <= 65535)
        let n=UInt16(bytes.count);var out=Data([1]);out.append(word(n));out.append(word(~n));out.append(bytes);return out
    }
    private func zip(_ files:[(String,Data)],method:UInt16=0,descriptor:Bool=false,
        flagsOverride:UInt16?=nil,mode:UInt32=0x81a4,trailingCompressed:Bool=false)throws->Data {
        var locals=Data(),central=Data();let flags=flagsOverride ?? (descriptor ? 0x808:0x800)
        for(path,raw)in files {
            let name=Data(path.utf8),offset=UInt32(locals.count),checksum=crc(raw)
            var payload=method == 8 ? deflated(raw):raw
            if trailingCompressed {payload.append(0)}
            locals.append(long(0x04034b50));locals.append(word(20));locals.append(word(flags));locals.append(word(method));locals.append(word(0));locals.append(word(0))
            locals.append(long(descriptor ? 0:checksum));locals.append(long(descriptor ? 0:UInt32(payload.count)));locals.append(long(descriptor ? 0:UInt32(raw.count)))
            locals.append(word(UInt16(name.count)));locals.append(word(0));locals.append(name);locals.append(payload)
            if descriptor {locals.append(long(0x08074b50));locals.append(long(checksum));locals.append(long(UInt32(payload.count)));locals.append(long(UInt32(raw.count)))}
            central.append(long(0x02014b50));central.append(word(0x314));central.append(word(20));central.append(word(flags));central.append(word(method));central.append(word(0));central.append(word(0));central.append(long(checksum));central.append(long(UInt32(payload.count)));central.append(long(UInt32(raw.count)));central.append(word(UInt16(name.count)));central.append(word(0));central.append(word(0));central.append(word(0));central.append(word(0));central.append(long(mode << 16));central.append(long(offset));central.append(name)
        }
        let offset=UInt32(locals.count),size=UInt32(central.count);locals.append(central)
        locals.append(long(0x06054b50));locals.append(word(0));locals.append(word(0));locals.append(word(UInt16(files.count)));locals.append(word(UInt16(files.count)));locals.append(long(size));locals.append(long(offset));locals.append(word(0));return locals
    }
    private func descriptor(_ bytes:Data,_ fixture:Fixture,files:[(String,Data)]?=nil,
        manifestHash:String?=nil,expanded:UInt64?=nil,entries:UInt64?=nil,archiveHash:String?=nil)throws->DeviceDeliveryPackageCandidate {
        let fs=files ?? fixture.files
        return try .validating(packageProfile:DeviceDeliveryPackageCandidate.profile,publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:UUID(uuidString:fixture.expected.revision.dashboardId)!,revision:UUID(uuidString:fixture.expected.revision.revision)!,manifestDigest:.validating(fixture.expected.revision.digest),manifestSHA256:.validating(manifestHash ?? hash(fixture.manifest)),archiveSHA256:.validating(archiveHash ?? hash(bytes)),compressedBytes:UInt64(bytes.count),expandedBytes:expanded ?? UInt64(fs.reduce(0){$0+$1.1.count}),archiveEntries:entries ?? UInt64(fs.count))
    }
    func testIncomingActualArchiveIsQualifiedAgainstOriginalCommonCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DeviceMixedInventoryStore(root: root, rootID: UUID()); try store.initializeExplicit()
        let owner = DeviceNativeInstallationContentOwner(installationID: UUID(), accountID: UUID(), locationID: nil, transitionID: UUID())
        let state = try DeviceMixedStructuralState.validating(generationID: UUID(), installationOwner: owner, entries: [], configuredEntryID: nil)
        let capture = try DeviceMixedInventoryQualificationHarness.scope(store) {
            try store.commitExact(operationID: UUID(), previous: nil, candidate: state, admissionEnabled: true, permit: $0).0
        }
        let fixture = try fixture(), archive = try zip(fixture.files), descriptor = try descriptor(archive, fixture)
        let id = UUID(), plan = Data("genuine reviewed cloud package".utf8), grantRoot = UUID(), packageRoot = UUID()
        let set = try DeviceResultingSetCandidate.validating(entries: [.validating(entryID: id, provenance: .cloud(descriptor))], configuredEntryID: id)
        let association: [String: Any] = ["schemaVersion": 1, "operationId": UUID().uuidString.lowercased(), "planId": UUID().uuidString.lowercased(),
            "installationId": owner.installationID.uuidString.lowercased(), "accountId": owner.accountID.uuidString.lowercased(), "locationId": NSNull(),
            "transitionId": owner.transitionID.uuidString.lowercased(), "planDigest": try DeviceNativeDeliveryAttachmentCodec.hash(plan), "planByteLength": plan.count]
        let header = try JSONSerialization.data(withJSONObject: association).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let wire: [String: Any] = ["packageProfile": DeviceDeliveryPackageCandidate.profile, "publicationId": descriptor.publicationID.uuidString.lowercased(),
            "projectId": descriptor.projectID.uuidString.lowercased(), "packageId": descriptor.packageID.uuidString.lowercased(), "dashboardId": descriptor.dashboardID.uuidString.lowercased(),
            "revision": descriptor.revision.uuidString.lowercased(), "manifestDigest": descriptor.manifestDigest.text, "manifestSha256": descriptor.manifestSHA256.text,
            "archiveSha256": descriptor.archiveSHA256.text, "compressedBytes": descriptor.compressedBytes, "expandedBytes": descriptor.expandedBytes, "archiveEntries": descriptor.archiveEntries]
        var command = association; command["sequence"] = "2"; command["executionExpiresAt"] = "2026-10-10T15:00:00Z"
        command["expectedInstalledSetGenerationId"] = state.generationID.uuidString.lowercased(); command["desiredSetGenerationId"] = UUID().uuidString.lowercased()
        command["resultingSet"] = ["schemaVersion": 1, "entries": [["entryId": id.uuidString.lowercased(), "provenance": ["kind": "cloud", "package": wire]]], "configuredEntryId": id.uuidString.lowercased()]
        command["resultingSetDigest"] = try DeviceDeliveryCandidateCodec.resultingSetDigest(set)
        let bytes = try JSONSerialization.data(withJSONObject: command), operation = UUID()
        func prepare(_ archive: Data) throws -> DeviceMixedPreparedCloudCommand {
            try .prepare(capture: capture, command: bytes, associationHeader: header, rawPlan: plan,
                nativeOperationID: UUID(), journalRootID: UUID(), packageRootID: packageRoot, grantRootID: grantRoot,
                grantOperationID: UUID(), grantRevisionID: UUID(), archives: [.init(entryID: id, preparationOperationID: operation,
                    archiveBytes: archive, profileID: "profile", revisionName: fixture.expected.revision.name, target: fixture.expected.target)])
        }
        let prepared = try prepare(archive)
        XCTAssertTrue(prepared.capture === capture)
        XCTAssertEqual(prepared.packageInputs.count, 1)
        guard case .supplied(let entryID, let preparation, let package) = prepared.packageInputs[0] else { return XCTFail("expected genuine supplied package") }
        XCTAssertEqual(entryID, id); XCTAssertEqual(preparation, operation)
        XCTAssertEqual(package.originalManifestBytes, fixture.manifest)
        XCTAssertEqual(package.files.first?.bytes, fixture.files[1].1)
        XCTAssertEqual(prepared.grantInput.entries.count, 1)
        XCTAssertTrue(prepared.grantInput.credentials.isEmpty)
        guard case .cloud(let entry, let grant) = prepared.candidate.entries[0] else { return XCTFail("expected cloud provenance") }
        XCTAssertEqual(entry.preparedPackage.rootID, packageRoot)
        XCTAssertEqual(grant.identity.rootID, grantRoot)
        var corrupt = archive; corrupt[30 + "manifest.json".utf8.count] ^= 1
        XCTAssertThrowsError(try prepare(corrupt))
    }
    #endif
}
