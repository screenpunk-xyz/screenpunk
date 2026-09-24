import Foundation
import Security
import CryptoKit

enum GoogleTVADBTrust {
    static let format = "rsa-public-key-sha256"
    /// adbd creates a new certificate (with new validity dates) for each TLS
    /// connection. Its RSA key is stable until the daemon restarts.
    static func pin(certificate: SecCertificate) throws -> Data {
        guard let key = SecCertificateCopyKey(certificate),
              let attributes = SecKeyCopyAttributes(key) as? [String: Any],
              attributes[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeRSA as String,
              let bytes = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            throw ADBError.cryptoError("The TV did not provide a usable RSA public key.")
        }
        return Data(SHA256.hash(data: bytes))
    }
}
