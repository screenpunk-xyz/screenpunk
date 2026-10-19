import Foundation
import XCTest
@testable import ScreenpunkCore

final class DeviceNativeDeliveryHTTPCodecTests: XCTestCase {
    private func command(_ plan:Data, sequence:String="9223372036854775807") throws -> (Data,String) {
        #if !canImport(CryptoKit)
        throw XCTSkip("Genuine SHA256 package/profile checks require CryptoKit; unsupported platforms fail closed")
        #else
        let uuid="00000000-0000-0000-0000-000000000001"
        let p=try DeviceDeliveryPackageCandidate.validating(packageProfile:DeviceDeliveryPackageCandidate.profile,
            publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:UUID(),revision:UUID(),
            manifestDigest:.validating(String(repeating:"a",count:64)),manifestSHA256:.validating(String(repeating:"b",count:64)),archiveSHA256:.validating(String(repeating:"c",count:64)),compressedBytes:1,expandedBytes:1,archiveEntries:1)
        let id=UUID(),set=try DeviceResultingSetCandidate.validating(entries:[.validating(entryID:id,provenance:.cloud(p))],configuredEntryID:id)
        let a:[String:Any]=["schemaVersion":1,"operationId":uuid,"planId":uuid,"installationId":uuid,"accountId":uuid,"locationId":uuid,"transitionId":uuid,"planDigest":try DeviceNativeDeliveryAttachmentCodec.hash(plan),"planByteLength":plan.count]
        let rawAssociation=try JSONSerialization.data(withJSONObject:a,options:[.sortedKeys])
        let header=rawAssociation.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        let package:[String:Any]=["packageProfile":DeviceDeliveryPackageCandidate.profile,"publicationId":p.publicationID.uuidString.lowercased(),"projectId":p.projectID.uuidString.lowercased(),"packageId":p.packageID.uuidString.lowercased(),"dashboardId":p.dashboardID.uuidString.lowercased(),"revision":p.revision.uuidString.lowercased(),"manifestDigest":p.manifestDigest.text,"manifestSha256":p.manifestSHA256.text,"archiveSha256":p.archiveSHA256.text,"compressedBytes":1,"expandedBytes":1,"archiveEntries":1]
        var o=a;o["sequence"]=sequence;o["expectedInstalledSetGenerationId"]=uuid;o["desiredSetGenerationId"]="00000000-0000-0000-0000-000000000002"
        o["resultingSet"]=["schemaVersion":1,"entries":[["entryId":id.uuidString.lowercased(),"provenance":["kind":"cloud","package":package]]],"configuredEntryId":id.uuidString.lowercased()]
        o["resultingSetDigest"]=try DeviceDeliveryCandidateCodec.resultingSetDigest(set);o["executionExpiresAt"]="2026-10-04T12:00:00.123Z"
        return (try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]),header)
        #endif
    }
    private func input(rootID:UUID,op:UUID=UUID(),plan:Data=Data("approved exact plan".utf8))throws->DeviceNativeDeliveryCommandBinding {
        let (c,h)=try command(plan)
        return try DeviceNativeDeliveryCommandBinding.bind(command:c,associationHeader:h,rawPlan:plan,nativeOperationID:op,journalRootID:rootID)
    }

    private func encode(_ object:[String:Any]) throws -> Data {try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])}
    private func response(_ binding:DeviceNativeDeliveryCommandBinding,_ id:UUID)throws->[String:Any] {
        let request=try DeviceNativeDeliveryHTTPCodec.activationRequest(binding:binding,requestID:id)
        var o=try XCTUnwrap(JSONSerialization.jsonObject(with:request) as? [String:Any])
        o["authorizationDigest"]=String(repeating:"d",count:64);o["authorizedAt"]="2026-10-05T12:00:00Z";o["expiresAt"]="2026-10-05T12:00:30Z";return o
    }
    func testOriginalActivationAssociationAndThirtySecondObservation()throws {
        let b=try input(rootID:UUID()),id=UUID(),o=try response(b,id)
        let observed=try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.activationResponse,binding:b,requestID:id)
        XCTAssertEqual(observed.activationRequestID,id)
        // Dates are historical observations; parsing does not reject later reporting or revive a lease.
        XCTAssertEqual(observed.authorizationDigest,String(repeating:"d",count:64))
        for field in ["operationId","planId","installationId","accountId","locationId","transitionId","expectedInstalledSetGenerationId","desiredSetGenerationId","planDigest","resultingSetDigest","sequence","activationRequestId","authorizationDigest"] {
            var bad=o;bad[field]=(bad[field] as! String)+"\n"
            XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(bad),kind:.activationResponse,binding:b,requestID:id))
        }
        var bad=o;bad["expiresAt"]="2026-10-05T12:00:31Z"
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(bad),kind:.activationResponse,binding:b,requestID:id))
    }
    func testLongFractionUsesExactCanonicalInterval()throws {
        let b=try input(rootID:UUID()),id=UUID();var o=try response(b,id)
        let fraction=String(repeating:"1",count:100)
        o["authorizedAt"]="2026-10-05T12:00:00."+fraction+"Z"
        o["expiresAt"]="2026-10-05T12:00:30."+fraction+"000Z"
        _=try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.activationResponse,binding:b,requestID:id)
        o["expiresAt"]="2026-10-05T12:00:30."+fraction+"1Z"
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.activationResponse,binding:b,requestID:id))
    }
    func testStrictRawBoundsUnknownDuplicateAndInvalidUnicode()throws {
        let b=try input(rootID:UUID()),id=UUID(),o=try response(b,id)
        var bad=o;bad["approved"]=true
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(bad),kind:.activationResponse,binding:b,requestID:id))
        for bytes in [Data(repeating:32,count:4097),Data("{\"schemaVersion\":1,\"\\u0073chemaVersion\":1}".utf8),Data("{\"x\":\"\\ud800\"}".utf8),Data([0xff])] {
            XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(bytes,kind:.activationResponse,binding:b,requestID:id))
        }
    }
    func testReceiptNullPairAndGenerationSemanticsAreNotOutcomeProof()throws {
        let b=try input(rootID:UUID()),id=UUID();var o=try response(b,id)
        o.removeValue(forKey:"authorizedAt");o.removeValue(forKey:"expiresAt")
        o["outcome"]="activated";o["previousGenerationId"]=b.expectedGenerationID.uuidString.lowercased();o["resultingGenerationId"]=b.desiredGenerationID.uuidString.lowercased();o["renderState"]="not-observed"
        _=try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.terminalRequest,binding:b,requestID:id,authorizationDigest:String(repeating:"d",count:64))
        o["activationRequestId"]=NSNull();o["authorizationDigest"]=NSNull()
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.terminalRequest,binding:b,requestID:nil))
        o["outcome"]="not_activated";o["resultingGenerationId"]=b.expectedGenerationID.uuidString.lowercased()
        _=try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.terminalRequest,binding:b,requestID:nil)
        o["authorizationDigest"]=String(repeating:"d",count:64)
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.terminalRequest,binding:b,requestID:nil))
        o.removeValue(forKey:"activationRequestId")
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.observe(encode(o),kind:.terminalRequest,binding:b,requestID:nil))
    }
    func testPollPreservesExactMemberBytesIncludingEscapesAndNestedBraces()throws {
        let member=Data("{ \"x\": [ {\"value\":\"}\\\"{\"} ], \"n\":1 }".utf8)
        var wrapper=Data("{\"nextCheckSeconds\":5,\"command\":".utf8);wrapper.append(member);wrapper.append(Data("}".utf8))
        XCTAssertEqual(try DeviceNativeDeliveryHTTPCodec.commandPoll(wrapper).commandBytes,member)
        for next in [5,900] {
            let null=Data("{\"command\":null,\"nextCheckSeconds\":\(next)}".utf8)
            XCTAssertNil(try DeviceNativeDeliveryHTTPCodec.commandPoll(null).commandBytes)
        }
        for raw in ["{\"command\":[],\"nextCheckSeconds\":5}","{\"command\":null,\"nextCheckSeconds\":6}","{\"command\":null,\"command\":{},\"nextCheckSeconds\":5}","{\"command\":null,\"nextCheckSeconds\":5,\"owner\":true}"] {
            XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.commandPoll(Data(raw.utf8)))
        }
        XCTAssertThrowsError(try DeviceNativeDeliveryHTTPCodec.commandPoll(Data(repeating:32,count:17*1024+1)))
    }

}
