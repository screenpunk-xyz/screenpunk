import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Unmounted byte inputs. No filesystem, ownership, migration, grant or approval interpretation.
struct DevicePackageFile: Equatable, Sendable {
    let path: String
    let bytes: Data
}
struct DevicePackageBytes: Equatable, Sendable {
    let manifest: Data
    let files: [DevicePackageFile]
}
struct DevicePackageExpectation: Equatable, Sendable {
    let revision: StoredRevision
    let target: DeviceProfile
    /// Explicit caller-supplied native profile identity, never inferred from an owner or device UUID.
    let profileID: String
}
enum DevicePackageQualificationError: Error, Equatable {
    case sizeLimit, invalidManifest, invalidExpectation, invalidPath, duplicatePath
    case assetMismatch, hashMismatch, digestMismatch, identityMismatch, targetMismatch, digestUnavailable
}

/// Validated supplied bytes only: no installation, durability, authorization or approval claim.
/// No Codable conformance or externally callable initializer can manufacture this result.
struct QualifiedDevicePackage: Equatable, Sendable {
    let originalManifestBytes: Data
    let canonicalManifestBytes: Data
    let manifest: DashboardManifest
    let revision: StoredRevision
    let files: [DevicePackageFile]
    let manifestSHA256: String
    let deploymentDigest: String
    fileprivate init(originalManifestBytes: Data, canonicalManifestBytes: Data, manifest: DashboardManifest,
                     revision: StoredRevision, files: [DevicePackageFile], manifestSHA256: String, deploymentDigest: String) {
        self.originalManifestBytes = originalManifestBytes; self.canonicalManifestBytes = canonicalManifestBytes
        self.manifest = manifest; self.revision = revision; self.files = files
        self.manifestSHA256 = manifestSHA256; self.deploymentDigest = deploymentDigest
    }
}

/// Additive pure qualification. Legacy PackageValidator/receiveDeployment/restore remain unchanged.
/// Manifest <=2MiB/depth32/65536 values; <=2000 assets; manifest+assets <=50MiB; paths <=1024 UTF8 bytes.
/// Limits fail closed without truncation. No ZIP/compressed-size, filesystem, credential or execution claim.
/// Digest matches native Codable projection: files sorted by Swift String, digest omitted, sortedKeys and
/// withoutEscapingSlashes. This is NOT the legacy JS canonical codec; unknown/ambiguous representations
/// are rejected here. Native numeric/Unicode fixture parity pins the current Foundation implementation,
/// not all future Foundation versions, all wire representations, or successful rendering on a device.
enum DevicePackageQualifier {
    static let manifestLimit = 2 * 1024 * 1024
    static let pathLimit = 1024
    static func qualify(_ input: DevicePackageBytes, expected: DevicePackageExpectation) throws -> QualifiedDevicePackage {
        // Bounds precede parsing, digest computation, per-asset snapshots and inventory allocations.
        guard !input.manifest.isEmpty, input.manifest.count <= manifestLimit,
              (1...PackageLimits.maxFiles).contains(input.files.count) else { throw DevicePackageQualificationError.sizeLimit }
        var total = input.manifest.count
        for file in input.files {
            guard !file.bytes.isEmpty, file.bytes.count <= PackageLimits.expandedBytes - total,
                  file.path.utf8.count <= pathLimit else { throw DevicePackageQualificationError.sizeLimit }
            total += file.bytes.count
        }
        try expectation(expected)
        #if !canImport(CryptoKit)
        throw DevicePackageQualificationError.digestUnavailable
        #else
        let manifestBytes = try snapshot(input.manifest, limit: manifestLimit)
        let manifest: DashboardManifest
        do { manifest = try DevicePackageManifestPreflight.decode(manifestBytes) }
        catch let error as DevicePackageQualificationError { throw error }
        catch { throw DevicePackageQualificationError.invalidManifest }
        do { try PackageValidator.validate(manifest) }
        catch { throw DevicePackageQualificationError.invalidManifest }
        guard manifest.dashboardId == expected.revision.dashboardId,
              manifest.revision == expected.revision.revision, manifest.name.utf8.elementsEqual(expected.revision.name.utf8) else {
            throw DevicePackageQualificationError.identityMismatch
        }
        var target = expected.target
        target.apply(orientation: expected.revision.orientation)
        guard expected.revision.matches(profile: target), manifest.target.profileId.utf8.elementsEqual(expected.profileID.utf8),
              manifest.target.width == expected.revision.width, manifest.target.height == expected.revision.height,
              manifest.target.orientation == expected.revision.orientation.rawValue else { throw DevicePackageQualificationError.targetMismatch }
        guard let declaredDigest = manifest.digest, isHash(declaredDigest), declaredDigest == expected.revision.digest else {
            throw DevicePackageQualificationError.digestMismatch
        }
        try path(manifest.entrypoint)
        guard manifest.entrypoint.hasSuffix(".html") else { throw DevicePackageQualificationError.invalidPath }
        var inventory: [String: ManifestFile] = [:]
        for declared in manifest.files {
            try path(declared.path)
            guard declared.path != "manifest.json", declared.bytes > 0, isHash(declared.sha256) else {
                throw DevicePackageQualificationError.invalidManifest
            }
            guard inventory.updateValue(declared, forKey: declared.path) == nil else { throw DevicePackageQualificationError.duplicatePath }
        }
        guard inventory.count == input.files.count, inventory[manifest.entrypoint] != nil else { throw DevicePackageQualificationError.assetMismatch }
        var supplied = Set<String>()
        var files: [DevicePackageFile] = []
        var copiedTotal = manifestBytes.count
        for file in input.files {
            try path(file.path)
            guard file.path != "manifest.json" else { throw DevicePackageQualificationError.invalidPath }
            guard supplied.insert(file.path).inserted else { throw DevicePackageQualificationError.duplicatePath }
            guard let declared = inventory[file.path], declared.bytes == file.bytes.count else { throw DevicePackageQualificationError.assetMismatch }
            let bytes = try snapshot(file.bytes, limit: min(declared.bytes, PackageLimits.expandedBytes - copiedTotal))
            guard bytes.count == declared.bytes else { throw DevicePackageQualificationError.assetMismatch }
            copiedTotal += bytes.count
            guard hash(bytes) == declared.sha256 else { throw DevicePackageQualificationError.hashMismatch }
            files.append(.init(path: file.path, bytes: bytes))
        }
        var canonical = manifest
        canonical.digest = nil
        canonical.files.sort { $0.path < $1.path }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let canonicalBytes: Data
        do { canonicalBytes = try encoder.encode(canonical) }
        catch { throw DevicePackageQualificationError.invalidManifest }
        let digest = hash(canonicalBytes)
        guard digest == declaredDigest else { throw DevicePackageQualificationError.digestMismatch }
        files.sort { $0.path < $1.path }
        return .init(originalManifestBytes: manifestBytes, canonicalManifestBytes: canonicalBytes,
                     manifest: manifest, revision: expected.revision, files: files,
                     manifestSHA256: hash(manifestBytes), deploymentDigest: digest)
        #endif
    }
    private static func expectation(_ expected: DevicePackageExpectation) throws {
        let revision = expected.revision
        guard revision.dashboardId.utf8.count == 36, revision.revision.utf8.count == 36,
              UUID(uuidString: revision.dashboardId) != nil, UUID(uuidString: revision.revision) != nil,
              revision.name.utf8.count <= 512,
              (1...128).contains(revision.name.unicodeScalars.count), isHash(revision.digest),
              (1...10000).contains(revision.width), (1...10000).contains(revision.height),
              (1...10000).contains(expected.target.width), (1...10000).contains(expected.target.height),
              expected.profileID.utf8.count <= 512, (1...128).contains(expected.profileID.unicodeScalars.count) else {
            throw DevicePackageQualificationError.invalidExpectation
        }
    }
    private static func path(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= pathLimit,
              path.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [46,95,45,47].contains($0) }),
              !path.contains(".."), path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." }) else {
            throw DevicePackageQualificationError.invalidPath
        }
    }
    private static func isHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func snapshot(_ data: Data, limit: Int) throws -> Data {
        try data.withUnsafeBytes { raw in
            guard raw.count > 0, raw.count <= limit, let pointer = raw.baseAddress else { throw DevicePackageQualificationError.sizeLimit }
            return Data(bytes: pointer, count: raw.count)
        }
    }
    #if canImport(CryptoKit)
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    #endif
}
