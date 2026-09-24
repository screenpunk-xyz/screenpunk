import Foundation
import Security
import CryptoKit

/// Google TV requires RSA, independent of Screenpunk's existing EC pairing key.
struct GoogleTVIdentity: @unchecked Sendable {
    let identity: SecIdentity
    let publicKey: Data
    static func loadOrCreate(tag: String = "xyz.screenpunk.google-tv.rsa.v1") throws -> GoogleTVIdentity {
        var item: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecReturnRef as String: true]
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let key: SecKey
        if status == errSecSuccess, let item, CFGetTypeID(item) == SecKeyGetTypeID() { key = item as! SecKey }
        else if status == errSecItemNotFound {
            var error: Unmanaged<CFError>?
            guard let created = SecKeyCreateRandomKey([
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048,
                kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: true, kSecAttrApplicationTag as String: Data(tag.utf8), kSecAttrLabel as String: tag, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            ] as CFDictionary, &error) else { throw GoogleTVError.message("Google TV identity could not be created. Check Keychain access.") }
            key = created
        } else { throw GoogleTVError.message("Google TV Keychain access is unavailable (\(status)). Existing credentials were preserved.") }
        guard let pub = SecKeyCopyPublicKey(key), let publicData = SecKeyCopyExternalRepresentation(pub, nil) as Data? else { throw GoogleTVError.message("RSA public key is unavailable.") }
        if let identity = find(publicData) { return .init(identity: identity, publicKey: publicData) }
        let cert = try makeCertificate(key: key, publicData: publicData)
        let added = SecItemAdd([kSecClass as String: kSecClassCertificate, kSecValueRef as String: cert, kSecAttrLabel as String: tag] as CFDictionary, nil)
        guard added == errSecSuccess || added == errSecDuplicateItem else { throw GoogleTVError.message("Could not save Google TV certificate (\(added)).") }
        guard let identity = find(publicData) else { throw GoogleTVError.message("Google TV identity could not be loaded after saving its certificate (\(added)). Existing credentials were preserved.") }
        return .init(identity: identity, publicKey: publicData)
    }
    static func makeCertificate(key: SecKey, publicData: Data) throws -> SecCertificate {
        // Keychain identifies certificates by issuer and serial, not their label.
        // Bind a positive 128-bit serial to this key so ADB and remote identities
        // can coexist. Existing certificates are reused before reaching here.
        var serial = Data(SHA256.hash(data: publicData).prefix(16))
        serial[0] = (serial[0] & 0x7f) | 0x40
        let algorithm = der(0x30, Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x0b,0x05,0x00]))
        let rsaAlgorithm = der(0x30, Data([0x06,0x09,0x2a,0x86,0x48,0x86,0xf7,0x0d,0x01,0x01,0x01,0x05,0x00]))
        let name = der(0x30, der(0x31, der(0x30, Data([0x06,0x03,0x55,0x04,0x03]) + der(0x0c, Data("Screenpunk Google TV".utf8)))))
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyyMMddHHmmss'Z'"
        let validity = der(0x30, der(0x18, Data(formatter.string(from: Date().addingTimeInterval(-86400)).utf8)) + der(0x18, Data(formatter.string(from: Date().addingTimeInterval(10 * 365 * 86400)).utf8)))
        let tbs = der(0x30, der(0xa0, der(0x02, Data([2]))) + der(0x02, serial) + algorithm + name + validity + name + der(0x30, rsaAlgorithm + der(0x03, Data([0]) + publicData)))
        guard let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data?,
              let cert = SecCertificateCreateWithData(nil, der(0x30, tbs + algorithm + der(0x03, Data([0]) + signature)) as CFData) else { throw GoogleTVError.message("Could not sign the Google TV identity. Allow this app's Keychain prompt.") }
        return cert
    }
    private static func find(_ publicData: Data) -> SecIdentity? {
        var result: CFTypeRef?
        guard SecItemCopyMatching([kSecClass as String: kSecClassIdentity, kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitAll] as CFDictionary, &result) == errSecSuccess else { return nil }
        for candidate in (result as? [SecIdentity] ?? []) {
            var cert: SecCertificate?
            if SecIdentityCopyCertificate(candidate, &cert) == errSecSuccess, let cert, let key = SecCertificateCopyKey(cert), let data = SecKeyCopyExternalRepresentation(key, nil) as Data?, data == publicData { return candidate }
        }
        return nil
    }
    static func der(_ tag: UInt8, _ content: Data) -> Data {
        let length = content.count
        let bytes: [UInt8] = length < 128 ? [UInt8(length)] : length < 256 ? [0x81, UInt8(length)] : [0x82, UInt8(length >> 8), UInt8(length & 255)]
        return Data([tag] + bytes) + content
    }
    static func rsaComponents(_ key: Data) throws -> Data {
        let bytes = Array(key); var offset = 0
        func value(_ expected: UInt8) throws -> Data {
            guard offset + 2 <= bytes.count, bytes[offset] == expected else { throw GoogleTVWire.Failure.malformed }; offset += 1
            var length = Int(bytes[offset]); offset += 1
            if length & 128 != 0 {
                let count = length & 127; guard count > 0, count <= 4, offset + count <= bytes.count else { throw GoogleTVWire.Failure.malformed }
                length = 0; for _ in 0..<count { length = length * 256 + Int(bytes[offset]); offset += 1 }
            }
            guard length <= bytes.count - offset else { throw GoogleTVWire.Failure.malformed }
            let start = offset; offset += length; return Data(bytes[start..<offset])
        }
        let sequence = try value(0x30)
        guard offset == bytes.count else { throw GoogleTVWire.Failure.malformed }
        // Decode the two positive ASN.1 INTEGERs without fixed RSA-size offsets.
        func integers(_ sequence: Data) throws -> Data {
            let b = Array(sequence); var i = 0; var out = Data()
            for _ in 0..<2 {
                guard i + 2 <= b.count, b[i] == 2 else { throw GoogleTVWire.Failure.malformed }; i += 1
                var n = Int(b[i]); i += 1
                if n & 128 != 0 { let count = n & 127; guard count > 0, count <= 4, i + count <= b.count else { throw GoogleTVWire.Failure.malformed }; n = 0; for _ in 0..<count { n = n * 256 + Int(b[i]); i += 1 } }
                guard n > 0, n <= b.count - i else { throw GoogleTVWire.Failure.malformed }
                var component = Array(b[i..<i+n]); i += n
                while component.count > 1 && component.first == 0 { component.removeFirst() }; out.append(contentsOf: component)
            }
            guard i == b.count else { throw GoogleTVWire.Failure.malformed }; return out
        }
        return try integers(sequence)
    }
    static func secret(client: Data, server: Data, code: String) throws -> Data {
        guard code.utf8.count == 6, code.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { throw GoogleTVError.message("Enter the six hexadecimal characters shown on the TV.") }
        let chars = Array(code); var bytes = Data()
        for i in stride(from: 0, to: 6, by: 2) { guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { throw GoogleTVError.message("Pairing code must use 0–9 and A–F.") }; bytes.append(byte) }
        let hash = Data(SHA256.hash(data: try rsaComponents(client) + rsaComponents(server) + bytes.dropFirst()))
        guard hash.first == bytes.first else { throw GoogleTVError.message("The pairing code does not match this TV. Try again.") }; return hash
    }
}
