import Foundation
import CNativeArchive
#if canImport(CryptoKit)
import CryptoKit
#endif

enum DeviceNativeArchiveQualificationError:Error,Equatable {
    case sizeLimit,descriptorMismatch,invalidZIP,invalidPath,duplicatePath,integrity,unsupportedPlatform,manifestMismatch
}
/// Genuine actual archive qualification only; no installation, durability, current admission,
/// approval, retained storage availability or rendering claim. No external result constructor.
struct QualifiedDeviceNativeArchive {
    let package:QualifiedDevicePackage
    let descriptor:DeviceDeliveryPackageCandidate
    let compressedBytes:Int,expandedBytes:Int,archiveEntries:Int
    fileprivate init(_ package:QualifiedDevicePackage,_ descriptor:DeviceDeliveryPackageCandidate,
                     _ compressed:Int,_ expanded:Int,_ entries:Int) {
        self.package=package;self.descriptor=descriptor
        compressedBytes=compressed;expandedBytes=expanded;archiveEntries=entries
    }
}
/// Exact Cloud ordinary-ZIP profile with existing native path cap1024 as a defensive subset.
/// No filesystem extraction or dependency download. Bounds precede arrays/output allocation.
/// AppleSDK libz raw DEFLATE only; unsupported platforms never claim a stored-only fallback.
enum DeviceNativeArchiveQualifier {
    private static let compressedLimit=25*1024*1024,expandedLimit=50*1024*1024
    private struct Entry {let path:String,method:UInt16,crc:UInt32,start:Int,compressed:Int,expanded:Int}
    static func qualify(_ archive:Data,descriptor:DeviceDeliveryPackageCandidate,
                        expected:DevicePackageExpectation)throws->QualifiedDeviceNativeArchive {
        guard archive.count >= 22,archive.count <= compressedLimit,
              descriptor.compressedBytes == UInt64(archive.count),
              (2...2000).contains(descriptor.archiveEntries),
              descriptor.expandedBytes <= UInt64(expandedLimit) else{throw DeviceNativeArchiveQualificationError.sizeLimit}
        #if !canImport(CryptoKit) || !(os(iOS) || os(macOS))
        throw DeviceNativeArchiveQualificationError.unsupportedPlatform
        #else
        guard hash(archive).utf8.elementsEqual(descriptor.archiveSHA256.text.utf8),
              expected.revision.dashboardId.utf8.elementsEqual(descriptor.dashboardID.uuidString.lowercased().utf8),
              expected.revision.revision.utf8.elementsEqual(descriptor.revision.uuidString.lowercased().utf8),
              expected.revision.digest.utf8.elementsEqual(descriptor.manifestDigest.text.utf8) else{throw DeviceNativeArchiveQualificationError.descriptorMismatch}
        let entries=try archive.withUnsafeBytes {raw in try preflight(raw,descriptor:descriptor)}
        var manifest:Data?,files:[DevicePackageFile]=[],expanded=0
        files.reserveCapacity(entries.count-1)
        for entry in entries {
            guard entry.expanded <= expandedLimit-expanded else{throw DeviceNativeArchiveQualificationError.sizeLimit}
            if entry.path == "manifest.json" {
                guard manifest == nil,entry.expanded <= DevicePackageQualifier.manifestLimit else{throw DeviceNativeArchiveQualificationError.manifestMismatch}
            }
            // Every declared count was qualified before the first output allocation.
            var output=Data(count:entry.expanded)
            let status:Int32=archive.withUnsafeBytes {input in output.withUnsafeMutableBytes {destination in
                sp_native_archive_decode(entry.method,
                    input.baseAddress!.advanced(by:entry.start).assumingMemoryBound(to:UInt8.self),entry.compressed,
                    destination.baseAddress!.assumingMemoryBound(to:UInt8.self),entry.expanded,entry.crc)
            }}
            guard status == 0 else{throw status == 2 ? DeviceNativeArchiveQualificationError.unsupportedPlatform:DeviceNativeArchiveQualificationError.integrity}
            expanded += output.count
            if entry.path == "manifest.json" {manifest=output}
            else{files.append(.init(path:entry.path,bytes:output))}
        }
        guard expanded == Int(descriptor.expandedBytes),let manifest,
              hash(manifest).utf8.elementsEqual(descriptor.manifestSHA256.text.utf8) else{throw DeviceNativeArchiveQualificationError.manifestMismatch}
        let package=try DevicePackageQualifier.qualify(.init(manifest:manifest,files:files),expected:expected)
        guard package.manifestSHA256.utf8.elementsEqual(descriptor.manifestSHA256.text.utf8),
              package.deploymentDigest.utf8.elementsEqual(descriptor.manifestDigest.text.utf8) else{throw DeviceNativeArchiveQualificationError.manifestMismatch}
        return .init(package,descriptor,archive.count,expanded,entries.count)
        #endif
    }
    #if canImport(CryptoKit)
    private static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    #endif
    private static func preflight(_ bytes:UnsafeRawBufferPointer,descriptor:DeviceDeliveryPackageCandidate)throws->[Entry] {
        let end=bytes.count-22
        func span(_ offset:Int,_ count:Int)throws {
            guard offset >= 0,count >= 0,offset <= bytes.count,count <= bytes.count-offset else{throw DeviceNativeArchiveQualificationError.invalidZIP}
        }
        func u16(_ offset:Int)throws->UInt16 {
            try span(offset,2);return UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8
        }
        func u32(_ offset:Int)throws->UInt32 {
            try span(offset,4);return UInt32(bytes[offset]) | UInt32(bytes[offset+1]) << 8 | UInt32(bytes[offset+2]) << 16 | UInt32(bytes[offset+3]) << 24
        }
        guard try u32(end) == 0x06054b50,try u16(end+4) == 0,try u16(end+6) == 0,
              try u16(end+8) == (try u16(end+10)),try u16(end+20) == 0 else{throw DeviceNativeArchiveQualificationError.invalidZIP}
        let count=Int(try u16(end+10)),centralSize=Int(try u32(end+12)),centralStart=Int(try u32(end+16))
        guard (2...2000).contains(count),UInt64(count) == descriptor.archiveEntries,
              centralStart >= 30,centralStart <= end,centralSize == end-centralStart else{throw DeviceNativeArchiveQualificationError.invalidZIP}
        var entries:[Entry]=[],paths=Set<String>(),cursor=centralStart,localOffset=0,expanded=0
        entries.reserveCapacity(count)
        for _ in 0..<count {
            try span(cursor,46)
            guard cursor <= end-46,try u32(cursor) == 0x02014b50 else{throw DeviceNativeArchiveQualificationError.invalidZIP}
            let version=try u16(cursor+6),flags=try u16(cursor+8),method=try u16(cursor+10)
            let time=try u16(cursor+12),date=try u16(cursor+14),crc=try u32(cursor+16)
            let compressed=Int(try u32(cursor+20)),size=Int(try u32(cursor+24)),nameLength=Int(try u16(cursor+28))
            let attributes=try u32(cursor+38),relative=Int(try u32(cursor+42))
            guard version <= 20,(flags == 0x800 || flags == 0x808),(method == 0 || method == 8),
                  try u16(cursor+30) == 0,try u16(cursor+32) == 0,try u16(cursor+34) == 0,
                  ((attributes >> 16) & 0xf000) == 0x8000,attributes & 0x10 == 0,
                  relative == localOffset,compressed > 0,compressed <= compressedLimit,
                  size > 0,size <= expandedLimit-expanded,
                  (1...DevicePackageQualifier.pathLimit).contains(nameLength),nameLength <= end-cursor-46 else{throw DeviceNativeArchiveQualificationError.invalidZIP}
            let nameStart=cursor+46
            let nameView=UnsafeRawBufferPointer(rebasing:bytes[nameStart..<nameStart+nameLength])
            guard nameView.allSatisfy({(65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 95 || $0 == 45 || $0 == 47}) else{throw DeviceNativeArchiveQualificationError.invalidPath}
            let path=String(decoding:nameView,as:UTF8.self)
            guard path.split(separator:"/",omittingEmptySubsequences:false).allSatisfy({!$0.isEmpty && $0 != "." && $0 != ".."}) else{throw DeviceNativeArchiveQualificationError.invalidPath}
            guard paths.insert(path).inserted else{throw DeviceNativeArchiveQualificationError.duplicatePath}
            try span(localOffset,30)
            guard localOffset <= centralStart-30,try u32(localOffset) == 0x04034b50,
                  try u16(localOffset+4) == version,try u16(localOffset+6) == flags,try u16(localOffset+8) == method,
                  try u16(localOffset+10) == time,try u16(localOffset+12) == date,
                  Int(try u16(localOffset+26)) == nameLength,try u16(localOffset+28) == 0 else{throw DeviceNativeArchiveQualificationError.invalidZIP}
            let dataStart=localOffset+30+nameLength
            guard dataStart <= centralStart,compressed <= centralStart-dataStart else{throw DeviceNativeArchiveQualificationError.invalidZIP}
            try span(localOffset+30,nameLength)
            guard bytes[localOffset+30..<dataStart].elementsEqual(nameView) else{throw DeviceNativeArchiveQualificationError.invalidZIP}
            let dataEnd=dataStart+compressed
            if flags & 8 != 0 {
                guard try u32(localOffset+14) == 0,try u32(localOffset+18) == 0,try u32(localOffset+22) == 0,
                      dataEnd <= centralStart-16,try u32(dataEnd) == 0x08074b50,
                      try u32(dataEnd+4) == crc,Int(try u32(dataEnd+8)) == compressed,Int(try u32(dataEnd+12)) == size else{throw DeviceNativeArchiveQualificationError.invalidZIP}
                localOffset=dataEnd+16
            } else {
                guard try u32(localOffset+14) == crc,Int(try u32(localOffset+18)) == compressed,Int(try u32(localOffset+22)) == size else{throw DeviceNativeArchiveQualificationError.invalidZIP}
                localOffset=dataEnd
            }
            if method == 0 {guard compressed == size else{throw DeviceNativeArchiveQualificationError.invalidZIP}}
            expanded += size
            entries.append(.init(path:path,method:method,crc:crc,start:dataStart,compressed:compressed,expanded:size))
            cursor=nameStart+nameLength
        }
        guard cursor == end,localOffset == centralStart,expanded == Int(descriptor.expandedBytes),
              paths.contains("manifest.json") else{throw DeviceNativeArchiveQualificationError.invalidZIP}
        return entries
    }
}
