import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Caller-selected scope only. No production root, reset expansion, default or migration policy.
struct DevicePackageProtectedScope: Equatable, Sendable {
    let legacyStateRoot: URL
    let legacyArchiveRoot: URL
    let resetRoot: URL
    let cloudRoot: URL
    let managementRoot: URL
    let preferencesRoot: URL
    let otherProtectedRoots: [URL]
    var roots: [URL] { [legacyStateRoot, legacyArchiveRoot, resetRoot, cloudRoot, managementRoot, preferencesRoot] + otherProtectedRoots }
}
struct DevicePackagePreparationRequest: Equatable, Sendable {
    let operationID: UUID
    let package: QualifiedDevicePackage
}
struct DevicePreparedPackageReference: Equatable, Sendable {
    let rootID: UUID
    let contentID: String
    let preparationOperationID: UUID
    let directory: String
}
enum DevicePackagePreparationError: Error, Equatable {
    case invalidMetadata, sizeLimit, scopeOverlap, unsafeBinding, conflict, capacity
    case repairRequired, outcomeUncertain, digestUnavailable
    case io(Int32)
}
struct PreparationIdentity: Codable, Equatable { let device: UInt64; let inode: UInt64 }
struct PreparationFile: Codable, Equatable { let path: String; let bytes: Int; let sha256: String }
struct PreparationPlan: Codable, Equatable {
    let rootID: UUID
    let operationID: UUID
    let ordinal: Int
    let contentID: String
    let revision: StoredRevision
    let profileID: String
    let files: [PreparationFile]
    let directories: [String]
    var leaf: String { "package.staging-cas-v1-" + contentID }
    var stage: String { "preparing-" + operationID.uuidString.lowercased() }
    var reference: DevicePreparedPackageReference { .init(rootID: rootID, contentID: contentID, preparationOperationID: operationID, directory: leaf) }
}
struct PreparationRecord: Codable, Equatable {
    enum Phase: String, Codable { case intent, prepared, terminal }
    let schemaVersion: Int
    let plan: PreparationPlan
    var phase: Phase
    var directoryIdentity: PreparationIdentity?
    var fileIdentities: [PreparationIdentity?]
    var directoryIdentities: [PreparationIdentity?]
    init(plan: PreparationPlan) {
        schemaVersion = 1; self.plan = plan; phase = .intent
        fileIdentities = Array(repeating: nil, count: plan.files.count)
        directoryIdentities = Array(repeating: nil, count: plan.directories.count)
    }
    func progresses(_ old: Self) -> Bool {
        guard let currentPlan = try? PackagePreparationCodec.encode(plan),
              let oldPlan = try? PackagePreparationCodec.encode(old.plan), currentPlan == oldPlan, schemaVersion == old.schemaVersion,
              old.directoryIdentity == nil || old.directoryIdentity == directoryIdentity,
              fileIdentities.count == old.fileIdentities.count, directoryIdentities.count == old.directoryIdentities.count else { return false }
        let order: [Phase] = [.intent, .prepared, .terminal]
        guard order.firstIndex(of: phase)! >= order.firstIndex(of: old.phase)! else { return false }
        return zip(old.fileIdentities, fileIdentities).allSatisfy { $0 == nil || $0 == $1 }
            && zip(old.directoryIdentities, directoryIdentities).allSatisfy { $0 == nil || $0 == $1 }
    }
}

/// Private-to-this-slice metadata codec. SHA-256 is always CryptoKit; no fallback/digest impersonation.
/// Metadata <=4MiB/depth32/65536 values; serialization exceeding the bound blocks before package effects.
enum PackagePreparationCodec {
    static let metadataLimit = 4 * 1024 * 1024
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(value)
        guard bytes.count <= metadataLimit else { throw DevicePackagePreparationError.sizeLimit }
        return bytes
    }
    static func hash(_ bytes: Data) throws -> String {
        #if canImport(CryptoKit)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #else
        throw DevicePackagePreparationError.digestUnavailable
        #endif
    }
    static func isHash(_ value: String) -> Bool { value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func contentID(_ files: [PreparationFile], digest: String) throws -> String {
        #if canImport(CryptoKit)
        var hash = SHA256()
        hash.update(data: Data("screenpunk-prepared-package-v1\0".utf8))
        func frame(_ value: Data) {
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: value)
        }
        frame(Data(digest.utf8))
        for file in files {
            frame(Data(file.path.utf8)); frame(Data(String(file.bytes).utf8)); frame(Data(file.sha256.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
        #else
        throw DevicePackagePreparationError.digestUnavailable
        #endif
    }
    static func makePlan(_ request: DevicePackagePreparationRequest, rootID: UUID, ordinal: Int) throws -> PreparationPlan {
        let package = request.package
        var files = [PreparationFile(path: "manifest.json", bytes: package.originalManifestBytes.count, sha256: package.manifestSHA256)]
        files += package.files.sorted { $0.path < $1.path }.map { file in
            PreparationFile(path: file.path, bytes: file.bytes.count, sha256: package.manifest.files.first { $0.path == file.path }!.sha256)
        }
        let plan = PreparationPlan(rootID: rootID, operationID: request.operationID, ordinal: ordinal,
            contentID: try contentID(files, digest: package.deploymentDigest), revision: package.revision,
            profileID: package.manifest.target.profileId, files: files, directories: try directories(files))
        try validate(plan); _ = try encode(PreparationRecord(plan: plan)); return plan
    }
    static func directories(_ files: [PreparationFile]) throws -> [String] {
        var result = Set<String>()
        for file in files {
            try path(file.path)
            let parts = file.path.split(separator: "/")
            guard parts.count <= 32 else { throw DevicePackagePreparationError.sizeLimit }
            if parts.count > 1 { for count in 1..<parts.count { result.insert(parts.prefix(count).joined(separator: "/")) } }
            guard result.count <= 4096 else { throw DevicePackagePreparationError.sizeLimit }
        }
        guard !files.contains(where: { result.contains($0.path) }) else { throw DevicePackagePreparationError.conflict }
        return result.sorted { ($0.split(separator: "/").count, $0) < ($1.split(separator: "/").count, $1) }
    }
    static func path(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 1024,
              value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46,95,45,47].contains($0) }),
              !value.contains(".."), value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." }) else { throw DevicePackagePreparationError.invalidMetadata }
    }
    static func validate(_ plan: PreparationPlan) throws {
        guard (1...129).contains(plan.ordinal), (1...2001).contains(plan.files.count), plan.directories.count <= 4096,
              isHash(plan.contentID), isHash(plan.revision.digest), plan.revision.dashboardId.utf8.count == 36,
              plan.revision.revision.utf8.count == 36, UUID(uuidString: plan.revision.dashboardId) != nil,
              UUID(uuidString: plan.revision.revision) != nil, plan.revision.name.utf8.count <= 512,
              (1...128).contains(plan.revision.name.unicodeScalars.count), plan.profileID.utf8.count <= 512,
              (1...128).contains(plan.profileID.unicodeScalars.count), (1...10000).contains(plan.revision.width),
              (1...10000).contains(plan.revision.height), plan.files[0].path == "manifest.json",
              plan.files[0].bytes <= DevicePackageQualifier.manifestLimit else { throw DevicePackagePreparationError.invalidMetadata }
        var total = 0; var seen = Set<String>()
        for file in plan.files {
            try path(file.path)
            guard file.bytes > 0, file.bytes <= PackageLimits.expandedBytes - total,
                  isHash(file.sha256), seen.insert(file.path).inserted else { throw DevicePackagePreparationError.invalidMetadata }
            total += file.bytes
        }
        guard Array(plan.files.dropFirst()).map(\.path) == plan.files.dropFirst().map(\.path).sorted(),
              plan.directories == (try directories(plan.files)), plan.contentID == (try contentID(plan.files, digest: plan.revision.digest)) else { throw DevicePackagePreparationError.invalidMetadata }
    }
    static func record(_ bytes: Data) throws -> PreparationRecord {
        let object = try object(bytes)
        try keys(object, required: ["schemaVersion", "plan", "phase", "fileIdentities", "directoryIdentities"], optional: ["directoryIdentity"])
        guard let plan = object["plan"] as? [String: Any] else { throw DevicePackagePreparationError.invalidMetadata }
        try keys(plan, required: ["rootID", "operationID", "ordinal", "contentID", "revision", "profileID", "files", "directories"])
        guard let revision = plan["revision"] as? [String: Any], let files = plan["files"] as? [[String: Any]] else { throw DevicePackagePreparationError.invalidMetadata }
        try keys(revision, required: ["revision","dashboardId","name","digest","orientation","width","height"])
        for file in files { try keys(file, required: ["path", "bytes", "sha256"]) }
        if let identity = object["directoryIdentity"] { try identityShape(identity) }
        for field in ["fileIdentities", "directoryIdentities"] {
            guard let array = object[field] as? [Any] else { throw DevicePackagePreparationError.invalidMetadata }
            for identity in array { if !(identity is NSNull) { try identityShape(identity) } }
        }
        let record = try JSONDecoder().decode(PreparationRecord.self, from: bytes)
        try validate(record.plan)
        guard record.schemaVersion == 1, record.fileIdentities.count == record.plan.files.count,
              record.directoryIdentities.count == record.plan.directories.count else { throw DevicePackagePreparationError.invalidMetadata }
        if record.phase == .intent {
            guard record.directoryIdentity == nil, record.fileIdentities.allSatisfy({ $0 == nil }), record.directoryIdentities.allSatisfy({ $0 == nil }) else { throw DevicePackagePreparationError.invalidMetadata }
        } else { guard record.directoryIdentity != nil else { throw DevicePackagePreparationError.invalidMetadata } }
        if record.phase == .terminal {
            guard record.fileIdentities.allSatisfy({ $0 != nil }), record.directoryIdentities.allSatisfy({ $0 != nil }) else { throw DevicePackagePreparationError.invalidMetadata }
        }
        return record
    }
    static func identityShape(_ value: Any) throws {
        guard let identity = value as? [String: Any] else { throw DevicePackagePreparationError.invalidMetadata }
        try keys(identity, required: ["device", "inode"])
    }
    static func keys(_ map: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        guard required.isSubset(of: Set(map.keys)), Set(map.keys).isSubset(of: required.union(optional)) else { throw DevicePackagePreparationError.invalidMetadata }
    }
    static func object(_ bytes: Data) throws -> [String: Any] {
        guard bytes.count <= metadataLimit else { throw DevicePackagePreparationError.sizeLimit }
        guard String(data: bytes, encoding: .utf8) != nil else { throw DevicePackagePreparationError.invalidMetadata }
        try bytes.withUnsafeBytes { raw in
            var scanner = Scanner(bytes: raw.bindMemory(to: UInt8.self), remaining: 65_536)
            try scanner.value(depth: 0); scanner.space()
            guard scanner.index == scanner.bytes.count else { throw DevicePackagePreparationError.invalidMetadata }
        }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw DevicePackagePreparationError.invalidMetadata }
        return object
    }
    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>; var remaining: Int; var index = 0
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func require(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw DevicePackagePreparationError.invalidMetadata }; index += 1 }
        mutating func value(depth: Int) throws {
            space(); remaining -= 1
            guard depth <= 32, remaining >= 0, index < bytes.count else { throw DevicePackagePreparationError.invalidMetadata }
            switch bytes[index] {
            case 123:
                index += 1; space(); var keys = Set<String>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    let key = try string(); guard keys.insert(key).inserted else { throw DevicePackagePreparationError.invalidMetadata }
                    space(); try require(58); try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 125 { index += 1; return }
                    try require(44); space()
                }
            case 91:
                index += 1; space()
                if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true {
                    try value(depth: depth + 1); space()
                    if index < bytes.count, bytes[index] == 93 { index += 1; return }
                    try require(44)
                }
            case 34: _ = try string()
            case 116: try literal("true")
            case 102: try literal("false")
            case 110: try literal("null")
            default:
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                guard text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil else { throw DevicePackagePreparationError.invalidMetadata }
            }
        }
        mutating func literal(_ value: String) throws { for byte in value.utf8 { try require(byte) } }
        mutating func hex() throws -> UInt16 {
            var result: UInt16 = 0
            for _ in 0..<4 {
                guard index < bytes.count else { throw DevicePackagePreparationError.invalidMetadata }
                let byte = bytes[index]; index += 1
                let value: UInt16
                switch byte { case 48...57: value = UInt16(byte-48); case 65...70: value = UInt16(byte-55); case 97...102: value = UInt16(byte-87); default: throw DevicePackagePreparationError.invalidMetadata }
                result = result * 16 + value
            }
            return result
        }
        mutating func string() throws -> String {
            let start = index; try require(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                guard byte >= 32 else { throw DevicePackagePreparationError.invalidMetadata }
                if byte == 92 {
                    guard index < bytes.count else { throw DevicePackagePreparationError.invalidMetadata }
                    let escape = bytes[index]; index += 1
                    if escape == 117 {
                        let scalar = try hex()
                        if (0xD800...0xDBFF).contains(scalar) {
                            try require(92); try require(117); let low = try hex()
                            guard (0xDC00...0xDFFF).contains(low) else { throw DevicePackagePreparationError.invalidMetadata }
                        } else if (0xDC00...0xDFFF).contains(scalar) { throw DevicePackagePreparationError.invalidMetadata }
                    } else if ![34,92,47,98,102,110,114,116].contains(escape) { throw DevicePackagePreparationError.invalidMetadata }
                }
            }
            throw DevicePackagePreparationError.invalidMetadata
        }
    }
}
