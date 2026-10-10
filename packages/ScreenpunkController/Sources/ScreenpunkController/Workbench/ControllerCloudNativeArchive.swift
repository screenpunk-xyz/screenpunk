import Foundation
import ScreenpunkCore
#if os(macOS)
/// A bounded native ZIP with a newly encoded persisted manifest. Historical
/// local archive bytes remain unchanged; the semantic deployment digest must match.
public enum ControllerCloudNativeArchive {
    public static func encode(manifest: DashboardManifest, files: [String: Data]) throws -> Data {
        var manifest = manifest; manifest.files.sort { $0.path < $1.path }
        try PackageValidator.validate(manifest)
        guard manifest.digest == (try DeploymentDigest.digest(for: manifest)),
              Set(files.keys) == Set(manifest.files.map(\.path)), !files.keys.contains("manifest.json") else { throw ControllerCloudError.invalidSource }
        for file in manifest.files {
            guard let bytes = files[file.path], bytes.count == file.bytes,
                  DeploymentDigest.sha256Hex(bytes) == file.sha256 else { throw ControllerCloudError.invalidSource }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        var contents = files; contents["manifest.json"] = try encoder.encode(manifest)
        guard contents.count <= 2_000 else { throw ControllerCloudError.sourceLimitExceeded }
        var zip = Data(), central = Data()
        func append<T: FixedWidthInteger>(_ value: T, to target: inout Data) { var little = value.littleEndian; withUnsafeBytes(of: &little) { target.append(contentsOf: $0) } }
        for path in contents.keys.sorted() {
            guard WorkspaceValidation.member(path), let payload = contents[path], payload.count <= 25 * 1024 * 1024,
                  path.utf8.count <= 65_535, zip.count <= 25 * 1024 * 1024 else { throw ControllerCloudError.sourceLimitExceeded }
            let name = Data(path.utf8), checksum = crc32(payload), size = UInt32(payload.count), offset = UInt32(zip.count)
            append(UInt32(0x04034b50), to: &zip); append(UInt16(20), to: &zip); append(UInt16(0x0800), to: &zip)
            append(UInt16(0), to: &zip); append(UInt16(0), to: &zip); append(UInt16(0x0021), to: &zip)
            append(checksum, to: &zip); append(size, to: &zip); append(size, to: &zip)
            append(UInt16(name.count), to: &zip); append(UInt16(0), to: &zip); zip.append(name); zip.append(payload)
            append(UInt32(0x02014b50), to: &central); append(UInt16(0x0314), to: &central); append(UInt16(20), to: &central)
            append(UInt16(0x0800), to: &central); append(UInt16(0), to: &central); append(UInt16(0), to: &central); append(UInt16(0x0021), to: &central)
            append(checksum, to: &central); append(size, to: &central); append(size, to: &central); append(UInt16(name.count), to: &central)
            for _ in 0..<4 { append(UInt16(0), to: &central) }
            append(UInt32(0o100644 << 16), to: &central); append(offset, to: &central); central.append(name)
        }
        let offset = UInt32(zip.count), size = UInt32(central.count); zip.append(central)
        append(UInt32(0x06054b50), to: &zip); append(UInt16(0), to: &zip); append(UInt16(0), to: &zip)
        append(UInt16(contents.count), to: &zip); append(UInt16(contents.count), to: &zip); append(size, to: &zip); append(offset, to: &zip); append(UInt16(0), to: &zip)
        guard zip.count <= 25 * 1024 * 1024 else { throw ControllerCloudError.sourceLimitExceeded }
        return zip
    }
    private static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0) } }
        return crc ^ UInt32.max
    }
}
#endif
