import Foundation

public enum PairingIdentityFactory: Sendable {
    public static func make(role: PairingRole, bytes: [UInt8]? = nil) -> PairingIdentity {
        if let bytes, bytes.count == PairingLimits.identityByteCount {
            return PairingIdentity(role: role, publicKey: bytes)
        }
        var key = [UInt8](repeating: 0, count: PairingLimits.identityByteCount)
        for i in key.indices {
            key[i] = UInt8.random(in: 0...255)
        }
        return PairingIdentity(role: role, publicKey: key)
    }

    public static func nonce(_ bytes: [UInt8]? = nil) -> [UInt8] {
        if let bytes, bytes.count == PairingLimits.sessionNonceByteCount {
            return bytes
        }
        return (0..<PairingLimits.sessionNonceByteCount).map { _ in UInt8.random(in: 0...255) }
    }
}
