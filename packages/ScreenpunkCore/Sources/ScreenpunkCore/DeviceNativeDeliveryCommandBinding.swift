import Foundation

/// Parsed bytes and stable association only. Never admission, approval, a validated
/// provisioning plan or a terminal ACK. Native operation/root IDs are supplied explicitly.
final class DeviceNativeDeliveryCommandBinding {
    struct Association: Codable, Equatable, Sendable {
        let operationID: UUID, planID: UUID, installationID: UUID, accountID: UUID
        let locationID: UUID?
        let transitionID: UUID
        let planDigest: String
        let planByteLength: Int
        private enum CodingKeys: String, CodingKey { case operationID, planID, installationID, accountID, locationID, transitionID, planDigest, planByteLength }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(operationID, forKey: .operationID); try c.encode(planID, forKey: .planID)
            try c.encode(installationID, forKey: .installationID); try c.encode(accountID, forKey: .accountID)
            if let locationID { try c.encode(locationID, forKey: .locationID) } else { try c.encodeNil(forKey: .locationID) }
            try c.encode(transitionID, forKey: .transitionID); try c.encode(planDigest, forKey: .planDigest)
            try c.encode(planByteLength, forKey: .planByteLength)
        }
    }
    let association: Association
    let nativeOperationID: UUID, journalRootID: UUID
    let sequence: UInt64, expectedGenerationID: UUID, desiredGenerationID: UUID
    let resultingSet: DeviceResultingSetCandidate
    let resultingSetDigest: String
    /// Kept internally for immutable persistence; not a secret or authority handle.
    let commandBytes: Data, planBytes: Data
    private init(_ association: Association, _ nativeOperation: UUID, _ root: UUID, _ sequence: UInt64,
                 _ expected: UUID, _ desired: UUID, _ set: DeviceResultingSetCandidate, _ digest: String,
                 _ command: Data, _ plan: Data) {
        self.association=association;nativeOperationID=nativeOperation;journalRootID=root
        self.sequence=sequence;expectedGenerationID=expected;desiredGenerationID=desired
        resultingSet=set;resultingSetDigest=digest;commandBytes=command;planBytes=plan
    }
    static func bind(command: Data, associationHeader: String, rawPlan: Data,
                     nativeOperationID: UUID, journalRootID: UUID) throws -> DeviceNativeDeliveryCommandBinding {
        try parse(command: command, associationHeader: associationHeader, rawPlan: rawPlan,
            nativeOperationID: nativeOperationID, journalRootID: journalRootID, mixedCapture: nil)
    }
    /// Separate common-inventory path. A retained entry is accepted only when its
    /// exact immutable provenance belongs to the original store-issued capture.
    static func bindMixed(command: Data, associationHeader: String, rawPlan: Data,
        nativeOperationID: UUID, journalRootID: UUID, capture: DeviceMixedInventoryStore.Capture) throws -> DeviceNativeDeliveryCommandBinding {
        try parse(command: command, associationHeader: associationHeader, rawPlan: rawPlan,
            nativeOperationID: nativeOperationID, journalRootID: journalRootID, mixedCapture: capture)
    }
    private static func parse(command: Data, associationHeader: String, rawPlan: Data,
        nativeOperationID: UUID, journalRootID: UUID, mixedCapture: DeviceMixedInventoryStore.Capture?) throws -> DeviceNativeDeliveryCommandBinding {
        typealias C = DeviceNativeDeliveryAttachmentCodec
        guard command.count <= 16384, rawPlan.count <= 65536, !rawPlan.isEmpty,
              associationHeader.utf8.prefix(1367).count <= 1366,
              associationHeader.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw C.Failure.capacity }
        var padded=associationHeader.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        padded += String(repeating:"=",count:(4-padded.utf8.count%4)%4)
        guard let fetched=Data(base64Encoded:padded), fetched.count <= 1024,
              fetched.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"").utf8.elementsEqual(associationHeader.utf8),
              String(data:rawPlan,encoding:.utf8) != nil else { throw C.Failure.invalidSchema }
        let fields:Set<String>=["schemaVersion","operationId","planId","planDigest","planByteLength","installationId","accountId","locationId","transitionId"]
        let fetch=try C.object(fetched,limit:1024,keys:fields)
        let preliminary = try JSONSerialization.jsonObject(with: command) as? [String: Any]
        let hasRemovals = preliminary?["removeEntryIds"] != nil
        let optionalFields: Set<String> = hasRemovals ? ["removeEntryIds"] : []
        let o=try C.object(command,limit:16384,keys:fields.union(["sequence","expectedInstalledSetGenerationId","desiredSetGenerationId","resultingSet","resultingSetDigest","executionExpiresAt"]).union(optionalFields))
        let a=try association(fetch), b=try association(o)
        guard a == b, a.planByteLength == rawPlan.count, try C.hash(rawPlan).utf8.elementsEqual(a.planDigest.utf8) else { throw C.Failure.invalidSchema }
        guard let sequence=o["sequence"] as? String, (1...19).contains(sequence.utf8.count),
              sequence.utf8.first != 48,sequence.utf8.allSatisfy({(48...57).contains($0)}),
              let number=UInt64(sequence), number <= 9223372036854775807 else { throw C.Failure.invalidSchema }
        let expected=try C.uuid(o["expectedInstalledSetGenerationId"]), desired=try C.uuid(o["desiredSetGenerationId"])
        guard expected != desired, let rawSet=o["resultingSet"] as? [String:Any],
              let expiry=o["executionExpiresAt"] as? String, expiry.utf8.count <= 64 else { throw C.Failure.invalidSchema }
        // Strict RFC3339 lexical form. Parsing a timestamp neither checks current time nor admits execution.
        let pattern="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})(?![\\s\\S])"
        guard expiry.range(of:pattern,options:.regularExpression) != nil else { throw C.Failure.invalidSchema }
        let parts=Array(expiry.utf8)
        func decimal(_ a:Int,_ b:Int)->Int { Int(String(decoding:parts[a..<b],as:UTF8.self))! }
        let year=decimal(0,4),month=decimal(5,7),day=decimal(8,10),hour=decimal(11,13),minute=decimal(14,16),second=decimal(17,19)
        let leap=year%4 == 0 && (year%100 != 0 || year%400 == 0)
        let days=[31,leap ? 29:28,31,30,31,30,31,31,30,31,30,31]
        guard year > 0,(1...12).contains(month),(1...days[month-1]).contains(day),hour < 24,minute < 60,second < 60 else{throw C.Failure.invalidSchema}
        if parts.last != 90 {
            let offset=parts.count-6
            guard decimal(offset+1,offset+3) < 24,decimal(offset+4,offset+6) < 60 else{throw C.Failure.invalidSchema}
        }
        let set=try DeviceDeliveryCandidateJSONDecoder.decodeResultingSet(JSONSerialization.data(withJSONObject:rawSet))
        let removals: [UUID]
        if hasRemovals {
            guard let raw = o["removeEntryIds"] as? [Any], raw.count <= 128 else { throw C.Failure.invalidSchema }
            removals = try raw.map { try C.uuid($0) }
            guard Set(removals).count == removals.count else { throw C.Failure.invalidSchema }
        } else { removals = [] }
        // Retained owner location is historical resource provenance. Current
        // command location is admitted only by the sealed authenticated status
        // and activation drivers; moving an installation never rewrites grants.
        if let capture = mixedCapture {
            let owner = capture.snapshot.installationOwner
            guard expected == capture.snapshot.generationID,
                  a.installationID == owner.installationID, a.accountID == owner.accountID,
                  a.transitionID == owner.transitionID else { throw C.Failure.invalidSchema }
            let desiredIDs = Set(set.entries.map(\.entryID))
            let omittedIDs = Set(capture.snapshot.entries.map(\.entryID)).subtracting(desiredIDs)
            guard Set(removals) == omittedIDs else { throw C.Failure.invalidSchema }
            for entry in set.entries {
                if case .retainedLocal(let retainedID, let digest) = entry.provenance {
                    guard entry.entryID == retainedID,
                          let original = capture.snapshot.entries.first(where: { $0.entryID == retainedID }),
                          case .retainedLocal(let local) = original,
                          local.entry.revision.digest == digest.text else { throw C.Failure.invalidSchema }
                }
            }
        } else {
            guard removals.isEmpty else { throw C.Failure.invalidSchema }
            guard !set.entries.isEmpty,set.entries.allSatisfy({if case .cloud = $0.provenance{return true};return false}) else { throw C.Failure.invalidSchema }
        }
        let digest=try C.hashText(o["resultingSetDigest"])
        guard try DeviceDeliveryCandidateCodec.resultingSetDigest(set).utf8.elementsEqual(digest.utf8) else { throw C.Failure.invalidSchema }
        return .init(a,nativeOperationID,journalRootID,number,expected,desired,set,digest,command,rawPlan)
    }
    private static func association(_ o:[String:Any]) throws -> Association {
        typealias C=DeviceNativeDeliveryAttachmentCodec
        guard try C.integer(o["schemaVersion"],maximum:1) == 1 else {throw C.Failure.invalidSchema}
        return try .init(operationID:C.uuid(o["operationId"]),planID:C.uuid(o["planId"]),installationID:C.uuid(o["installationId"]),accountID:C.uuid(o["accountId"]),locationID:o["locationId"] is NSNull ? nil : C.uuid(o["locationId"]),transitionID:C.uuid(o["transitionId"]),planDigest:C.hashText(o["planDigest"]),planByteLength:Int(C.integer(o["planByteLength"],maximum:65536)))
    }
}
