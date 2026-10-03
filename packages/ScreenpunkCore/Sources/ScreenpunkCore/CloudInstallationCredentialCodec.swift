import Foundation

/// Installation proof format accepted by Cloud commit e7029fecc86a48934f48ca55604ce92c22dd2604.
/// This codec neither generates nor retains credentials.
public enum CloudInstallationCredentialCodec {
    public enum Failure: Error, Equatable, Sendable { case invalidByteCount, invalidEncoding }
    public static let randomByteCount = 48
    private static let prefix = "spni1_"

    public static func encode(randomBytes: Data) throws -> String {
        guard randomBytes.count == randomByteCount else { throw Failure.invalidByteCount }
        return prefix + randomBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    public static func decode(_ wireValue: String) throws -> Data {
        guard wireValue.utf8.count == 70, wireValue.hasPrefix(prefix) else { throw Failure.invalidEncoding }
        let payload = String(wireValue.dropFirst(prefix.count))
        guard payload.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }),
              let bytes = Data(base64Encoded: payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")),
              bytes.count == randomByteCount,
              try encode(randomBytes: bytes) == wireValue else { throw Failure.invalidEncoding }
        return bytes
    }
}
