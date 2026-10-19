import Foundation

/// Supplied association and resource observations, never current Cloud admission or archive proof.
struct DeviceNativeProvisioningRequest: GrantSecretRedacted {
    let roots: DeviceProvisioningRoots
    let delivery: DeviceNativeDeliveryCommandBinding
    let grantOperationID: UUID
    let baseline: DeviceStructuralStore.NativeGenesisCheckpoint
    let candidate: DeviceNativeStructuralState
    let packages: [DeviceProvisioningPackageInput]
    let grantInput: DeviceNativeGrantRevisionInput
    let qualifiedGrant: QualifiedDeviceNativeGrantRevision
}
struct DeviceNativeProvisioningIntentBody: Codable {
    struct Package: Codable {
        let entryID:UUID
        let reference:DevicePreparedPackageReference
        init(entryID:UUID,reference:DevicePreparedPackageReference){self.entryID=entryID;self.reference=reference}
        private struct Reference:Codable {let rootID:UUID,contentID:String,preparationOperationID:UUID,directory:String}
        private enum CodingKeys:String,CodingKey {case entryID,reference}
        init(from decoder:Decoder)throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            entryID=try c.decode(UUID.self,forKey:.entryID)
            let r=try c.decode(Reference.self,forKey:.reference)
            reference = .init(rootID:r.rootID,contentID:r.contentID,preparationOperationID:r.preparationOperationID,directory:r.directory)
        }
        func encode(to encoder:Encoder)throws {
            var c=encoder.container(keyedBy:CodingKeys.self)
            try c.encode(entryID,forKey:.entryID)
            try c.encode(Reference(rootID:reference.rootID,contentID:reference.contentID,preparationOperationID:reference.preparationOperationID,directory:reference.directory),forKey:.reference)
        }
    }
    let schemaVersion:Int
    let roots:DeviceProvisioningRoots
    let nativeOperationID:UUID,grantOperationID:UUID
    let association:DeviceNativeDeliveryCommandBinding.Association
    let expectedGenerationID:UUID,desiredGenerationID:UUID
    let baselineDigest:String,candidateDigest:String
    let candidateByteCount:Int,privateAttemptByteCount:Int
    let packages:[Package]
    let grantIdentity:DeviceGrantRevisionIdentity
    let grantPublicMetadata:Data
}
/// File-private construction retains nonsecret immutable bytes only. Not a command/admission/ACK.
/// Private qualification is freshly checked but is NOT persisted/bound by this value. Equal public
/// bytes/length can represent different secrets; later resource commands need independent exact
/// private-attempt binding and must never use this joined intent as original secret proof.
final class DeviceValidatedNativeProvisioningPlan {
    let roots:DeviceProvisioningRoots,nativeOperationID:UUID
    let intentBytes:Data,candidateBytes:Data
    let delivery:DeviceNativeDeliveryCommandBinding
    fileprivate init(_ request:DeviceNativeProvisioningRequest,_ intent:Data,_ candidate:Data) {
        roots=request.roots;nativeOperationID=request.delivery.nativeOperationID
        delivery=request.delivery;intentBytes=intent;candidateBytes=candidate
    }
}
/// Additive sizing frame only. Grant stores do NOT decode/write/execute schema3 yet.
enum DeviceNativePrivateAttemptV3 {
    private struct Frame:Encodable {let schemaVersion:Int;let rootID:UUID;let operationID:UUID;let input:DeviceNativeGrantRevisionInput;let completeSetIntent:Data}
    static func byteCount(input:DeviceNativeGrantRevisionInput,operationID:UUID,intent:Data)throws->Int {
        guard intent.count <= 32768 else{throw DeviceStructuralStoreError.tooLarge}
        // The native qualifier preflights all private input allocation-bearing fields first.
        // Reserve framing/base64 expansion before creating the larger private frame.
        let inputBytes=try DeviceLocalCompleteSetBounds.encode(input,maximum:4*1024*1024)
        guard inputBytes.count+((intent.count+2)/3)*4+1024 <= 4*1024*1024 else{throw DeviceStructuralStoreError.tooLarge}
        let bytes=try DeviceLocalCompleteSetBounds.encode(Frame(schemaVersion:3,rootID:input.identity.rootID,operationID:operationID,input:input,completeSetIntent:intent),maximum:4*1024*1024)
        return bytes.count
    }
}
enum DeviceNativeProvisioningPlanner {
    static func qualify(_ request:DeviceNativeProvisioningRequest)throws->DeviceValidatedNativeProvisioningPlan {
        let delivery=request.delivery,candidate=request.candidate
        // Candidate/grant owner records the original durable installation root.
        // Its historical location is not current Cloud permission. Exact live
        // command location is checked by the fixed authenticated dispatch owner.
        guard request.packages.count <= 12,candidate.entries.count <= 12,
              request.roots.journalID == delivery.journalRootID,
              request.baseline.rootID == request.roots.structuralID,
              request.grantInput.identity.rootID == request.roots.grantID,
              request.baseline.state.entries.isEmpty,request.baseline.state.configuredEntryID == nil,
              request.baseline.state.owner == candidate.owner,candidate.owner == request.grantInput.owner,
              candidate.owner.installationID == delivery.association.installationID,
              candidate.owner.accountID == delivery.association.accountID,
              candidate.owner.transitionID == delivery.association.transitionID,
              request.baseline.state.generationID == delivery.expectedGenerationID,
              candidate.generationID == delivery.desiredGenerationID,
              candidate.entries.count == delivery.resultingSet.entries.count,
              candidate.configuredEntryID == delivery.resultingSet.configuredEntryID else{throw DeviceStructuralStoreError.conflict}
        var expectations:[DeviceGrantEntryExpectation]=[],refs:[DeviceNativeProvisioningIntentBody.Package]=[],seen=Set<UUID>()
        for (entry,cloud) in zip(candidate.entries,delivery.resultingSet.entries) {
            guard entry.entryID == cloud.entryID,
                  case .cloud(let descriptor)=cloud.provenance,entry.package == descriptor else{throw DeviceStructuralStoreError.conflict}
        }
        guard request.packages.count == candidate.entries.count else{throw DeviceStructuralStoreError.conflict}
        for item in request.packages {
            let id:UUID,reference:DevicePreparedPackageReference,package:QualifiedDevicePackage
            switch item {
            case .supplied(let entryID,let operation,let supplied):
                id=entryID;package=supplied;reference=try PackagePreparationCodec.expectedReference(.init(operationID:operation,package:supplied),rootID:request.roots.packageID)
            case .retained(let entryID,let supplied,let verified):
                guard supplied == verified.reference else{throw DeviceStructuralStoreError.conflict}
                id=entryID;reference=supplied;package=verified.package
            }
            guard seen.insert(id).inserted,reference.rootID == request.roots.packageID,
                  let entry=candidate.entries.first(where:{$0.entryID == id}),entry.preparedPackage == reference,
                  package.revision.dashboardId.utf8.elementsEqual(entry.package.dashboardID.uuidString.lowercased().utf8),
                  package.revision.digest.utf8.elementsEqual(entry.package.manifestDigest.text.utf8),
                  package.manifestSHA256.utf8.elementsEqual(entry.package.manifestSHA256.text.utf8),
                  package.revision.revision.utf8.elementsEqual(entry.package.revision.uuidString.lowercased().utf8) else{throw DeviceStructuralStoreError.conflict}
            // Archive hash/size are merely retained descriptors: no ZIP qualification exists here.
            expectations.append(.init(entryID:id,package:package));refs.append(.init(entryID:id,reference:reference))
        }
        let fresh=try DeviceNativeGrantRevisionQualifier.qualify(request.grantInput,expectedEntries:expectations)
        guard fresh.exactlyMatches(request.qualifiedGrant) else{throw DeviceStructuralStoreError.conflict}
        guard ((fresh.publicMetadataBytes.count+2)/3)*4+refs.count*1024+4096 <= 32768 else{throw DeviceStructuralStoreError.tooLarge}
        refs.sort{a,b in candidate.entries.firstIndex(where:{$0.entryID == a.entryID})! < candidate.entries.firstIndex(where:{$0.entryID == b.entryID})!}
        let snapshot=try DeviceNativeStructuralStateCodec.encode(candidate)
        let envelope=try DeviceNativeStructuralEnvelopeCodec.encode(.init(operationID:delivery.nativeOperationID,expectedGenerationID:delivery.expectedGenerationID,snapshotBytes:snapshot))
        let baselineDigest=try DeviceNativeDeliveryAttachmentCodec.hash(request.baseline.stateBytes)
        let candidateDigest=try DeviceNativeDeliveryAttachmentCodec.hash(envelope)
        var count=0
        for _ in 0..<4 {
            let body=DeviceNativeProvisioningIntentBody(schemaVersion:2,roots:request.roots,nativeOperationID:delivery.nativeOperationID,grantOperationID:request.grantOperationID,association:delivery.association,expectedGenerationID:delivery.expectedGenerationID,desiredGenerationID:delivery.desiredGenerationID,baselineDigest:baselineDigest,candidateDigest:candidateDigest,candidateByteCount:envelope.count,privateAttemptByteCount:count,packages:refs,grantIdentity:fresh.identity,grantPublicMetadata:fresh.publicMetadataBytes)
            let intent=try DeviceNativeProvisioningIntentCodec.encode(body)
            let actual=try DeviceNativePrivateAttemptV3.byteCount(input:request.grantInput,operationID:request.grantOperationID,intent:intent)
            if actual == count {_ = try DeviceNativeProvisioningIntentCodec.decode(intent);return .init(request,intent,envelope)}
            count=actual
        }
        throw DeviceStructuralStoreError.tooLarge
    }
}
enum DeviceNativeProvisioningIntentCodec {
    static func encode(_ body:DeviceNativeProvisioningIntentBody)throws->Data {try DeviceLocalCompleteSetBounds.encode(body,maximum:32768)}
    static func decode(_ bytes:Data)throws->DeviceNativeProvisioningIntentBody {
        let o=try StructuralStoreCodec.object(bytes,limit:32768)
        try StructuralStoreCodec.keys(o,required:["schemaVersion","roots","nativeOperationID","grantOperationID","association","expectedGenerationID","desiredGenerationID","baselineDigest","candidateDigest","candidateByteCount","privateAttemptByteCount","packages","grantIdentity","grantPublicMetadata"])
        guard let roots=o["roots"] as? [String:Any],let identity=o["grantIdentity"] as? [String:Any],let association=o["association"] as? [String:Any],let packages=o["packages"] as? [[String:Any]],packages.count <= 12 else{throw DeviceStructuralStoreError.invalidRecord}
        try StructuralStoreCodec.keys(roots,required:["journalID","structuralID","packageID","grantID"])
        try StructuralStoreCodec.keys(identity,required:["rootID","revisionID"])
        try StructuralStoreCodec.keys(association,required:["operationID","planID","installationID","accountID","locationID","transitionID","planDigest","planByteLength"])
        for p in packages {
            try StructuralStoreCodec.keys(p,required:["entryID","reference"])
            guard let r=p["reference"] as? [String:Any] else{throw DeviceStructuralStoreError.invalidRecord}
            try StructuralStoreCodec.keys(r,required:["rootID","contentID","preparationOperationID","directory"])
        }
        let body=try JSONDecoder().decode(DeviceNativeProvisioningIntentBody.self,from:bytes)
        guard body.schemaVersion == 2,body.expectedGenerationID != body.desiredGenerationID,
              body.grantIdentity.rootID == body.roots.grantID,body.candidateByteCount > 0,body.candidateByteCount <= 128*1024,
              body.privateAttemptByteCount > 0,body.privateAttemptByteCount <= 4*1024*1024,
              body.grantPublicMetadata.count <= 256*1024,Set(body.packages.map(\.entryID)).count == body.packages.count,
              body.packages.allSatisfy({$0.reference.rootID == body.roots.packageID}),try encode(body) == bytes else{throw DeviceStructuralStoreError.invalidRecord}
        _ = try DeviceNativeDeliveryAttachmentCodec.hashText(body.baselineDigest)
        _ = try DeviceNativeDeliveryAttachmentCodec.hashText(body.candidateDigest)
        return body
    }
}
