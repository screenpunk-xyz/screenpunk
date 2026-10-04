import Foundation

struct DeviceProvisioningRoots:Codable,Equatable,Sendable {
    let journalID:UUID,structuralID:UUID,packageID:UUID,grantID:UUID
}
enum DeviceProvisioningPackageInput {
    case supplied(entryID:UUID,operationID:UUID,package:QualifiedDevicePackage)
    case retained(entryID:UUID,reference:DevicePreparedPackageReference,verified:DeviceVerifiedPreparedPackage)
}
struct DeviceProvisioningPlanRequest:GrantSecretRedacted {
    let roots:DeviceProvisioningRoots
    let operationID:UUID,grantOperationID:UUID
    let expectedGenerationID:UUID?
    let baseline:DeviceLocalCompleteSetBaseline
    let snapshot:DeviceStructuralSnapshot
    let owner:PairingIdentity
    let packages:[DeviceProvisioningPackageInput]
    let grantInput:DeviceGrantRevisionInput
    let qualifiedGrant:QualifiedDeviceGrantRevision
}
struct ProvisioningIntentBody:Codable {
    let schemaVersion:Int
    let roots:DeviceProvisioningRoots
    let operationID:UUID,grantOperationID:UUID
    let grantIdentity:DeviceGrantRevisionIdentity
    let expectedOld:Data?
    let candidate:Data
    let grantPublicMetadata:Data
    let privateAttemptByteCount:Int
}
/// Only this factory constructs the bounded plan. It retains NO secrets/private attempt bytes.
/// Supplied/retained observations are not current resource or management authority qualification.
final class DeviceValidatedProvisioningPlan {
    let operationID:UUID
    let roots:DeviceProvisioningRoots
    let canonicalBytes:Data
    fileprivate init(_ body:ProvisioningIntentBody,_ bytes:Data){operationID=body.operationID;roots=body.roots;canonicalBytes=bytes}
}
/// Future private wrapper encoder only; no backend/write/getter. Exact same encoder is to be used by
/// future bound preparation. Complete private wrapper <=4MiB, including nonsecret binding expansion.
enum DeviceProvisioningPrivateAttemptV2 {
    private struct Frame:Encodable {let schemaVersion:Int;let rootID:UUID;let operationID:UUID;let input:DeviceGrantRevisionInput;let completeSetIntent:Data}
    static func encoded(_ request:DeviceGrantPreparationRequest,intent:Data)throws->Data {
        guard intent.count <= ProvisioningIntentCodec.limit else{throw DeviceLocalCompleteSetFailure.sizeLimit}
        let original=try GrantPreparationCodec.attempt(request,rootID:request.input.identity.rootID)
        guard original.count + ((intent.count+2)/3)*4 + 1024 <= GrantPreparationCodec.intentLimit else{throw DeviceLocalCompleteSetFailure.sizeLimit}
        let canonical=try GrantPreparationCodec.decodeAttempt(original)
        return try GrantPreparationCodec.encode(Frame(schemaVersion:2,rootID:canonical.rootID,operationID:canonical.operationID,input:canonical.input,completeSetIntent:intent),limit:GrantPreparationCodec.intentLimit)
    }
}
enum DeviceProvisioningPlanner {
    static func qualify(_ request:DeviceProvisioningPlanRequest)throws->DeviceValidatedProvisioningPlan {
        guard request.packages.count <= 12,request.snapshot.entries.count <= 12,
              request.grantInput.identity.rootID == request.roots.grantID else{throw DeviceLocalCompleteSetFailure.sizeLimit}
        let snapshot=request.snapshot
        var snapshotBudget=2048
        for entry in snapshot.entries {
            for field in [entry.displayName,entry.packageDirectory,entry.revision.dashboardId,entry.revision.revision,entry.revision.name,entry.revision.digest] { snapshotBudget += try DeviceLocalCompleteSetBounds.string(field) }
            snapshotBudget += 512
        }
        if let legacy=snapshot.grantSet { snapshotBudget += try DeviceLocalCompleteSetBounds.string(legacy) }
        guard snapshotBudget <= 64*1024,request.owner.publicKey.count <= PairingLimits.identityByteCount else{throw DeviceLocalCompleteSetFailure.sizeLimit}
        guard snapshot.schemaVersion == 1,request.expectedGenerationID != snapshot.generationID,
              snapshot.entries.count == request.packages.count,Set(snapshot.entries.map(\.entryID)).count == snapshot.entries.count,
              snapshot.entries.isEmpty ? snapshot.configuredEntryID == nil:snapshot.entries.contains(where:{$0.entryID == snapshot.configuredEntryID}),
              request.owner.isWellFormed,request.owner.role == .controller,
              snapshot.contentOwner?.publicKey == request.owner.publicKey,snapshot.contentOwner?.role == .controller,
              request.grantInput.owner.publicKey == request.owner.publicKey,request.grantInput.owner.role == .controller else{throw DeviceLocalCompleteSetFailure.invalidInput}
        let old:Data?
        switch request.baseline {
        case .initialExplicit(let legacy):guard request.expectedGenerationID == nil,exact(legacy,snapshot.grantSet) else{throw DeviceLocalCompleteSetFailure.baselineMismatch};old=nil
        case .expectedEnvelope(let bytes):
            guard bytes.count <= 128*1024 else{throw DeviceLocalCompleteSetFailure.sizeLimit}
            let prior=try StructuralStoreCodec.envelope(bytes)
            guard prior.snapshot.generationID == request.expectedGenerationID,prior.operationID != request.operationID,exact(prior.snapshot.grantSet,snapshot.grantSet) else{throw DeviceLocalCompleteSetFailure.baselineMismatch};old=bytes
        }
        var expectations:[DeviceGrantEntryExpectation]=[],references:[DeviceLocalCompleteSetReferences.Package]=[],seen=Set<UUID>()
        for item in request.packages {
            let entryID:UUID,reference:DevicePreparedPackageReference,package:QualifiedDevicePackage
            switch item {
            case .supplied(let id,let op,let supplied):entryID=id;package=supplied;reference=try PackagePreparationCodec.expectedReference(.init(operationID:op,package:supplied),rootID:request.roots.packageID)
            case .retained(let id,let ref,let verified):
                guard exactReference(ref,verified.reference) else{throw DeviceLocalCompleteSetFailure.packageMismatch};entryID=id;reference=ref;package=verified.package
            }
            guard reference.rootID == request.roots.packageID,seen.insert(entryID).inserted,
                  let entry=snapshot.entries.first(where:{$0.entryID == entryID}),entry.provenance == .retainedLocal,
                  entry.packageDirectory.utf8.elementsEqual(reference.directory.utf8),
                  try DeviceLocalCompleteSetBounds.encode(entry.revision,maximum:8192) == DeviceLocalCompleteSetBounds.encode(package.revision,maximum:8192) else{throw DeviceLocalCompleteSetFailure.packageMismatch}
            expectations.append(.init(entryID:entryID,package:package))
            references.append(.init(entryID:entryID,rootID:reference.rootID,contentID:reference.contentID,preparationOperationID:reference.preparationOperationID,directory:reference.directory))
        }
        let fresh=try DeviceGrantRevisionQualifier.qualify(request.grantInput,expectedEntries:expectations)
        guard fresh.exactlyMatches(request.qualifiedGrant) else{throw DeviceGrantPreparationError.conflict}
        references.sort{a,b in snapshot.entries.firstIndex(where:{$0.entryID == a.entryID})! < snapshot.entries.firstIndex(where:{$0.entryID == b.entryID})!}
        let refs=DeviceLocalCompleteSetReferences(schemaVersion:1,structuralRootID:request.roots.structuralID,operationID:request.operationID,generationID:snapshot.generationID,packages:references,grants:.init(identity:fresh.identity,preparationOperationID:request.grantOperationID))
        let intent=try DeviceLocalCompleteSetBounds.encode(refs,maximum:32*1024)
        let candidate=try DeviceLocalCompleteSetBounds.encode(DeviceStructuralCommitEnvelope(operationID:request.operationID,expectedGenerationID:request.expectedGenerationID,snapshot:snapshot,intent:intent,outcome:intent),maximum:128*1024)
        _ = try StructuralStoreCodec.envelope(candidate)
        let privateRequest=DeviceGrantPreparationRequest(operationID:request.grantOperationID,input:request.grantInput,qualified:fresh,expectedEntries:expectations)
        // The wrapper binds the EXACT final journal bytes. Its decimal length field reaches
        // a bounded fixed point; no separate excluded-size interpretation is accepted.
        var size=0
        for _ in 0..<4 {
            let body=ProvisioningIntentBody(schemaVersion:1,roots:request.roots,operationID:request.operationID,grantOperationID:request.grantOperationID,grantIdentity:fresh.identity,expectedOld:old,candidate:candidate,grantPublicMetadata:fresh.publicMetadataBytes,privateAttemptByteCount:size)
            let bytes=try ProvisioningIntentCodec.encode(body)
            let actual=try DeviceProvisioningPrivateAttemptV2.encoded(privateRequest,intent:bytes).count
            if actual == size { _ = try ProvisioningIntentCodec.decode(bytes);return .init(body,bytes) }
            size=actual
        }
        throw DeviceLocalCompleteSetFailure.sizeLimit
    }
    private static func exact(_ a:String?,_ b:String?)->Bool{switch(a,b){case(nil,nil):return true;case(.some(let x),.some(let y)):return x.utf8.elementsEqual(y.utf8);default:return false}}
    static func exactReference(_ a:DevicePreparedPackageReference,_ b:DevicePreparedPackageReference)->Bool{a.rootID == b.rootID && a.preparationOperationID == b.preparationOperationID && a.contentID.utf8.elementsEqual(b.contentID.utf8) && a.directory.utf8.elementsEqual(b.directory.utf8)}
}
enum ProvisioningIntentCodec {
    static let limit=1024*1024
    static func encode<T:Encodable>(_ value:T)throws->Data{let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];let bytes=try e.encode(value);guard bytes.count <= limit else{throw DeviceLocalCompleteSetFailure.sizeLimit};return bytes}
    static func decode(_ bytes:Data)throws->ProvisioningIntentBody {
        let object=try StructuralStoreCodec.object(bytes,limit:limit)
        try StructuralStoreCodec.keys(object,required:["schemaVersion","roots","operationID","grantOperationID","grantIdentity","candidate","grantPublicMetadata","privateAttemptByteCount"],optional:["expectedOld"])
        guard let roots=object["roots"] as? [String:Any],let identity=object["grantIdentity"] as? [String:Any] else{throw DeviceLocalCompleteSetFailure.invalidInput}
        try StructuralStoreCodec.keys(roots,required:["journalID","structuralID","packageID","grantID"]);try StructuralStoreCodec.keys(identity,required:["rootID","revisionID"])
        let body=try JSONDecoder().decode(ProvisioningIntentBody.self,from:bytes),candidate=try StructuralStoreCodec.envelope(body.candidate)
        guard body.schemaVersion == 1,body.grantIdentity.rootID == body.roots.grantID,body.operationID == candidate.operationID,
              body.privateAttemptByteCount > 0,body.privateAttemptByteCount <= 4*1024*1024,body.grantPublicMetadata.count <= 256*1024 else{throw DeviceLocalCompleteSetFailure.invalidInput}
        if let old=body.expectedOld{let previous=try StructuralStoreCodec.envelope(old);guard previous.snapshot.generationID == candidate.expectedGenerationID,previous.operationID != candidate.operationID,previous.snapshot.grantSet.map({Data($0.utf8)}) == candidate.snapshot.grantSet.map({Data($0.utf8)}) else{throw DeviceLocalCompleteSetFailure.baselineMismatch}}
        else{guard candidate.expectedGenerationID == nil else{throw DeviceLocalCompleteSetFailure.baselineMismatch}}
        let refs=try DeviceLocalCompleteSetRestoreCodec.references(candidate.intent)
        guard refs.structuralRootID == body.roots.structuralID,refs.operationID == body.operationID,refs.grants.identity == body.grantIdentity,refs.grants.preparationOperationID == body.grantOperationID,refs.packages.allSatisfy({$0.rootID == body.roots.packageID}),candidate.intent == candidate.outcome else{throw DeviceLocalCompleteSetFailure.invalidInput}
        // Metadata is schema projected, never private credentials/token/Generic secret fields.
        try DeviceGrantRevisionPreflight.validate(body.grantPublicMetadata)
        guard var metadata=try JSONSerialization.jsonObject(with:body.grantPublicMetadata) as? [String:Any] else{throw DeviceLocalCompleteSetFailure.invalidInput}
        guard metadata["credentials"] == nil else{throw DeviceLocalCompleteSetFailure.invalidInput}
        metadata["credentials"] = []
        guard var entries=metadata["entries"] as? [[String:Any]] else{throw DeviceLocalCompleteSetFailure.invalidInput}
        for index in entries.indices {
            if let generic=entries[index]["generic"] as? [String:Any],let items=generic["entries"] as? [[String:Any]] {guard items.allSatisfy({$0["secret"] == nil}) else{throw DeviceLocalCompleteSetFailure.invalidInput}}
            if var home=entries[index]["homeAssistant"] as? [String:Any]{guard home["token"] == nil else{throw DeviceLocalCompleteSetFailure.invalidInput};home["token"]="";entries[index]["homeAssistant"]=home}
        }
        metadata["entries"]=entries
        let projected=try JSONSerialization.data(withJSONObject:metadata,options:[.sortedKeys])
        let publicInput=try DeviceGrantRevisionPreflight.decode(projected)
        guard publicInput.schemaVersion == 1,publicInput.identity == body.grantIdentity,
              publicInput.owner.isWellFormed,publicInput.owner.role == .controller,
              publicInput.owner.publicKey == candidate.snapshot.contentOwner?.publicKey,
              publicInput.entries.count == candidate.snapshot.entries.count,
              Set(publicInput.entries.map(\.entryID)).count == publicInput.entries.count else{throw DeviceLocalCompleteSetFailure.invalidInput}
        for entry in candidate.snapshot.entries {
            guard let declared=publicInput.entries.first(where:{$0.entryID == entry.entryID}),
                  try DeviceLocalCompleteSetBounds.encode(declared.revision,maximum:8192) == DeviceLocalCompleteSetBounds.encode(entry.revision,maximum:8192) else{throw DeviceLocalCompleteSetFailure.invalidInput}
        }
        guard refs.packages.map(\.entryID) == candidate.snapshot.entries.map(\.entryID),refs.generationID == candidate.snapshot.generationID else{throw DeviceLocalCompleteSetFailure.invalidInput}
        for (entry,reference) in zip(candidate.snapshot.entries,refs.packages) {guard entry.packageDirectory.utf8.elementsEqual(reference.directory.utf8) else{throw DeviceLocalCompleteSetFailure.invalidInput}}
        guard try encode(body) == bytes else{throw DeviceLocalCompleteSetFailure.invalidInput};return body
    }
}
