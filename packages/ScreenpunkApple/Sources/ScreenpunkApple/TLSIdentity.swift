import Foundation
import ScreenpunkCore
#if canImport(Security)
import Security
#endif
#if canImport(Security)
public struct TLSIdentityMaterial: @unchecked Sendable {
    public var identity: SecIdentity
    public var pin: [UInt8]
    public var role: PairingRole
    public var pairingIdentity: PairingIdentity {
        PairingIdentity(role: role, publicKey: pin)
    }
}

public enum TLSIdentity {
    static let controllerTag = "xyz.screenpunk.tls.controller"
    static let deviceTag = "xyz.screenpunk.tls.device"
    private static let lifecycleLock = NSLock()

    /// Persistent per-user identity. The Mac workbench and `screenpunk-mcp`
    /// share the controller tag, so a device sees one owner whichever client paired it.
    public static func loadOrCreate(role: PairingRole) throws -> TLSIdentityMaterial {
        let tag = role == .controller ? controllerTag : deviceTag
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return try TLSIdentityLifecycle.loadOrCreate(role: role, tag: tag, store: KeychainIdentityStore())
    }

    static func make(role: PairingRole, commonName: String) throws -> TLSIdentityMaterial {
        let unique = "\(commonName).\(UUID().uuidString)"
        return try generate(role: role, commonName: unique, tag: Data(unique.utf8))
    }

    private struct KeychainIdentityStore: TLSIdentityStore {
        func load(role: PairingRole, tag: String) throws -> TLSIdentityMaterial? {
            try TLSIdentity.load(role: role, tag: tag)
        }
        func create(role: PairingRole, tag: String) throws -> TLSIdentityMaterial {
            try generate(role: role, commonName: tag, tag: Data(tag.utf8))
        }
    }

    /// Keep the original application tag and default Keychain/access-group
    /// scope. Only absence of this exact private-key query permits creation.
    static func persistentKeyQuery(tag: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
    }

    /// Never turn access denial, a locked Keychain, or an invalid query into absence.
    static func lookupFound(status: OSStatus) throws -> Bool {
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess else { throw TLSIdentityLoadError.keychain(status: status) }
        return true
    }

    private static func load(role: PairingRole, tag: String) throws -> TLSIdentityMaterial? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching(persistentKeyQuery(tag: tag) as CFDictionary, &item)
        guard try lookupFound(status: status) else { return nil }
        guard let item else { throw TLSIdentityLoadError.corruptMaterial }
        let matches = (item as? [AnyObject]) ?? [item as AnyObject]
        guard matches.count == 1, let privateKey = secKey(matches[0]) else {
            throw TLSIdentityLoadError.corruptMaterial
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else {
            throw TLSIdentityLoadError.corruptMaterial
        }
        if let identity = try findIdentity(matchingPublic: publicData) {
            return TLSIdentityMaterial(identity: identity, pin: PeerPin.sha256(publicData), role: role)
        }
        let certificate = try makeCertificate(
            commonName: tag,
            publicPoint: [UInt8](publicData),
            privateKey: privateKey
        )
        let identity = try associate(certificate: certificate, publicData: publicData, label: tag)
        return TLSIdentityMaterial(identity: identity, pin: PeerPin.sha256(publicData), role: role)
    }

    private static func generate(
        role: PairingRole,
        commonName: String,
        tag: Data
    ) throws -> TLSIdentityMaterial {
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrLabel as String: commonName,
                kSecAttrApplicationTag as String: tag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            throw TransferFailure.validationFailed
        }
        let certificate = try makeCertificate(
            commonName: commonName,
            publicPoint: [UInt8](publicData),
            privateKey: privateKey
        )
        let identity = try associate(certificate: certificate, publicData: publicData, label: commonName)
        return TLSIdentityMaterial(identity: identity, pin: PeerPin.sha256(publicData), role: role)
    }

    private static func makeCertificate(
        commonName: String,
        publicPoint: [UInt8],
        privateKey: SecKey
    ) throws -> SecCertificate {
        let certDER = try SelfSignedCertificate.make(
            commonName: commonName,
            publicPoint: publicPoint,
            privateKey: privateKey
        )
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw TransferFailure.validationFailed
        }
        return certificate
    }

    private static func associate(
        certificate: SecCertificate,
        publicData: Data,
        label: String
    ) throws -> SecIdentity {
        // Do not delete an existing certificate to recover from a failed load.
        // A missing certificate may be associated with the existing private key.
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label
        ]
        let certStatus = SecItemAdd(add as CFDictionary, nil)
        guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
            throw TLSIdentityLoadError.keychain(status: certStatus)
        }
#if os(macOS)
        var created: SecIdentity?
        let identityStatus = SecIdentityCreateWithCertificate(nil, certificate, &created)
        if try lookupFound(status: identityStatus) {
            guard let created else { throw TLSIdentityLoadError.corruptMaterial }
            return try verified(identity: created, matchingPublic: publicData)
        }
#endif
        if let identity = try findIdentity(matchingPublic: publicData) {
            return identity
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecAttrLabel as String: label
        ] as CFDictionary, &item)
        guard try lookupFound(status: status), let item, let identity = secIdentity(item) else {
            throw TLSIdentityLoadError.corruptMaterial
        }
        return try verified(identity: identity, matchingPublic: publicData)
    }

    private static func verified(identity: SecIdentity, matchingPublic publicData: Data) throws -> SecIdentity {
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate,
              let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
              data == publicData else { throw TLSIdentityLoadError.corruptMaterial }
        return identity
    }

    private static func findIdentity(matchingPublic publicData: Data) throws -> SecIdentity? {
        var items: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ] as CFDictionary, &items)
        guard try lookupFound(status: status) else { return nil }
        guard let items else { throw TLSIdentityLoadError.corruptMaterial }
        let candidates: [AnyObject]
        if let array = items as? [AnyObject] {
            candidates = array
        } else {
            candidates = [items as AnyObject]
        }
        for candidate in candidates {
            guard let identity = secIdentity(candidate) else { throw TLSIdentityLoadError.corruptMaterial }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate,
                  let key = SecCertificateCopyKey(certificate),
                  let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
            else {
                throw TLSIdentityLoadError.corruptMaterial
            }
            guard data == publicData else { continue }
            return identity
        }
        return nil
    }

    static func pin(from trust: SecTrust) -> [UInt8]? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = chain.first,
              let key = SecCertificateCopyKey(certificate),
              let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
        else {
            return nil
        }
        return PeerPin.sha256(data)
    }

    private static func secIdentity(_ item: CFTypeRef) -> SecIdentity? {
        guard CFGetTypeID(item) == SecIdentityGetTypeID() else { return nil }
        return (item as! SecIdentity)
    }

    private static func secKey(_ item: CFTypeRef) -> SecKey? {
        guard CFGetTypeID(item) == SecKeyGetTypeID() else { return nil }
        return (item as! SecKey)
    }
}

enum SelfSignedCertificate {
    static func make(commonName: String, publicPoint: [UInt8], privateKey: SecKey) throws -> Data {
        let tbs = tbsCertificate(commonName: commonName, publicPoint: publicPoint)
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            Data(tbs) as CFData,
            &error
        ) as Data?
        else {
            throw TransferFailure.validationFailed
        }
        let algorithm = der(0x30, oidECDSAWithSHA256)
        let sigBits = der(0x03, [0x00] + [UInt8](signature))
        return Data(der(0x30, tbs + algorithm + sigBits))
    }

    private static func tbsCertificate(commonName: String, publicPoint: [UInt8]) -> [UInt8] {
        let version = der(0xA0, der(0x02, [0x02]))
        let serial = der(0x02, [0x01])
        let signatureAlg = der(0x30, oidECDSAWithSHA256)
        let name = directoryName(commonName)
        let validity = der(0x30, utcTime("250101000000Z") + utcTime("350101000000Z"))
        let spki = subjectPublicKeyInfo(publicPoint)
        return der(0x30, version + serial + signatureAlg + name + validity + name + spki)
    }

    private static func directoryName(_ commonName: String) -> [UInt8] {
        let cnBytes = Array(commonName.utf8)
        let cn = der(0x30, oidCommonName + der(0x0C, cnBytes))
        return der(0x30, der(0x31, cn))
    }

    private static func subjectPublicKeyInfo(_ publicPoint: [UInt8]) -> [UInt8] {
        let algorithm = der(0x30, oidECPublicKey + oidPrime256v1)
        let bitString = der(0x03, [0x00] + publicPoint)
        return der(0x30, algorithm + bitString)
    }

    private static func utcTime(_ value: String) -> [UInt8] {
        der(0x17, Array(value.utf8))
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    private static func derLength(_ count: Int) -> [UInt8] {
        if count < 0x80 { return [UInt8(count)] }
        if count < 0x100 { return [0x81, UInt8(count)] }
        return [0x82, UInt8((count >> 8) & 0xFF), UInt8(count & 0xFF)]
    }

    private static let oidECDSAWithSHA256: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    private static let oidECPublicKey: [UInt8] = [0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidPrime256v1: [UInt8] = [0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidCommonName: [UInt8] = [0x06, 0x03, 0x55, 0x04, 0x03]
}
#endif
