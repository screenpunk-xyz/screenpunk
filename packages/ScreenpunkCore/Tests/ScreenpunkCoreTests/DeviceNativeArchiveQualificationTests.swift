import Foundation
import XCTest
import CNativeArchive
#if canImport(CryptoKit)
import CryptoKit
#endif
@testable import ScreenpunkCore

final class DeviceNativeArchiveQualificationTests:XCTestCase {
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
    func testActualStoredDeflateAndSignedDescriptorQualifyGenuineNativePackage()throws {
        let f=try fixture()
        for method:UInt16 in [0,8] {for signed in [false,true] {
            let bytes=try zip(f.files,method:method,descriptor:signed),d=try descriptor(bytes,f)
            let result=try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:d,expected:f.expected)
            XCTAssertEqual(result.archiveEntries,2);XCTAssertEqual(result.compressedBytes,bytes.count)
            XCTAssertEqual(result.expandedBytes,f.files.reduce(0){$0+$1.1.count})
            XCTAssertEqual(result.package.originalManifestBytes,f.manifest)
            XCTAssertEqual(result.package.files.first?.bytes,f.files[1].1)
            XCTAssertEqual(result.package.manifestSHA256,d.manifestSHA256.text)
        }}
    }
    func testDescriptorHashLengthManifestAndExpandedCountMustMatchActualBytes()throws {
        let f=try fixture(),bytes=try zip(f.files)
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:descriptor(bytes,f,archiveHash:String(repeating:"f",count:64)),expected:f.expected))
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:descriptor(bytes,f,manifestHash:String(repeating:"f",count:64)),expected:f.expected))
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:descriptor(bytes,f,expanded:1),expected:f.expected))
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:descriptor(bytes,f,entries:3),expected:f.expected))
        let descriptorValue=try descriptor(bytes,f)
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes+Data([0]),descriptor:descriptorValue,expected:f.expected))
    }
    func testDuplicateTraversalFlagsSpecialNodeAndTrailingLayoutReject()throws {
        let f=try fixture()
        for files in [f.files+[f.files[1]],[f.files[0],("../index.html",f.files[1].1)],[f.files[0],("/index.html",f.files[1].1)],[f.files[0],("index\\.html",f.files[1].1)]] {
            let bytes=try zip(files);XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:descriptor(bytes,f,files:files),expected:f.expected))
        }
        for bytes in [try zip(f.files,flagsOverride:0x801),try zip(f.files,mode:0xa1ff),try zip(f.files)+Data([0])] {
            XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(bytes,descriptor:descriptor(bytes,f),expected:f.expected))
        }
    }
    func testCRCAndCompleteDeflateConsumptionAreActualChecks()throws {
        let f=try fixture();var stored=try zip(f.files)
        stored[30+"manifest.json".utf8.count] ^= 1
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(stored,descriptor:descriptor(stored,f),expected:f.expected))
        let trailing=try zip(f.files,method:8,trailingCompressed:true)
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(trailing,descriptor:descriptor(trailing,f),expected:f.expected))
        var truncated=try zip(f.files,method:8);truncated.removeLast()
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(truncated,descriptor:descriptor(truncated,f),expected:f.expected))
    }
    func testCentralLocalDisagreementAndEntryCountBoundRejectBeforeOutput()throws {
        let f=try fixture();var mismatch=try zip(f.files)
        mismatch[6]=0x08 // local flags disagree with central UTF8-only flags
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(mismatch,descriptor:descriptor(mismatch,f),expected:f.expected))
        var count=try zip(f.files);let end=count.count-22
        count.replaceSubrange(end+8..<end+12,with:word(2001)+word(2001))
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(count,descriptor:descriptor(count,f),expected:f.expected))
    }
    #else
    func testUnsupportedPlatformCannotClaimActualArchiveQualification()throws {
        let archive=Data(repeating:0,count:22),hash=String(repeating:"a",count:64),dashboard=UUID(),revision=UUID()
        let descriptor=try DeviceDeliveryPackageCandidate.validating(packageProfile:DeviceDeliveryPackageCandidate.profile,publicationID:UUID(),projectID:UUID(),packageID:UUID(),dashboardID:dashboard,revision:revision,manifestDigest:.validating(hash),manifestSHA256:.validating(hash),archiveSHA256:.validating(hash),compressedBytes:22,expandedBytes:1,archiveEntries:2)
        let expected=DevicePackageExpectation(revision:.init(revision:revision.uuidString.lowercased(),dashboardId:dashboard.uuidString.lowercased(),name:"Unsupported",digest:hash,orientation:.portrait,width:390,height:844),target:.init(deviceId:"fixture",name:"Fixture"),profileID:"profile")
        XCTAssertThrowsError(try DeviceNativeArchiveQualifier.qualify(archive,descriptor:descriptor,expected:expected)){XCTAssertEqual($0 as? DeviceNativeArchiveQualificationError,.unsupportedPlatform)}
        var output:UInt8=0,input:UInt8=0
        XCTAssertEqual(sp_native_archive_decode(0,&input,1,&output,1,0),2)
    }
    #endif
}
