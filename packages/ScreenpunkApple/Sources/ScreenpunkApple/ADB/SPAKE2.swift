// Adapted from h33h/iadb-ios (MIT). See Resources/ADB-LICENSE.txt.
import Foundation
import CryptoKit

/// SPAKE2 client (alice role) compatible with BoringSSL's implementation.
/// Used for ADB wireless debugging pairing (Android 11+).
struct SPAKE2Client {
    private let passwordHash: [UInt8]  // 64-byte SHA-512 of raw password (for transcript)
    private let x: [UInt8]             // private scalar (reduced mod l, then left_shift_3)
    private let wScalar: [UInt8]       // password scalar = SHA-512(password) reduced mod l
    let outgoingMessage: Data          // T = x·B + w·M, 32 bytes

    // Names: 16 bytes each (15 chars + implicit null terminator)
    // Matches AOSP: static const uint8_t kClientName[] = "adb pair client";
    // sizeof(kClientName) = 16
    static let clientName: Data = {
        var d = Data("adb pair client".utf8)
        d.append(0)
        return d // 16 bytes
    }()
    static let serverName: Data = {
        var d = Data("adb pair server".utf8)
        d.append(0)
        return d // 16 bytes
    }()

    /// Initialize SPAKE2 client with the pairing code as password.
    init(password: Data) throws {
        var randomBytes = [UInt8](repeating: 0, count: 64)
        guard SecRandomCopyBytes(kSecRandomDefault, 64, &randomBytes) == errSecSuccess else { throw SPAKE2Error.randomGenerationFailed }
        try self.init(password: password, randomBytes: randomBytes)
    }

    // Explicit entropy injection for reproducible interoperability vectors.
    init(password: Data, randomBytes: [UInt8]) throws {
        guard randomBytes.count == 64 else { throw SPAKE2Error.randomGenerationFailed }
        // Compute and store password hash (needed in transcript)
        let hash = SHA512.hash(data: password)
        self.passwordHash = [UInt8](hash)

        // Password scalar: SHA-512(password) reduced mod l
        // BoringSSL: x25519_sc_reduce treats bytes as little-endian
        self.wScalar = Self.passwordScalar(passwordHash)

        var xScalar = Self.reduceModL(randomBytes)
        // BoringSSL applies left_shift_3 to the private scalar (cofactor clearing)
        Self.leftShift3(&xScalar)
        self.x = xScalar

        // Compute T = x·B + w·M
        guard let M = EdPoint.M else {
            throw SPAKE2Error.invalidMessage("Failed to decode SPAKE2 M constant")
        }
        let xB = EdPoint.B.scalarMult(x)
        let wM = M.scalarMult(wScalar)
        let pointT = xB.add(wM)
        self.outgoingMessage = Data(pointT.encode())
    }

    /// Process the server's SPAKE2 message and return key material (64-byte SHA-512 of transcript).
    func processServerMessage(_ serverMsg: Data) throws -> Data {
        guard serverMsg.count == 32 else {
            throw SPAKE2Error.invalidMessage("Server message must be 32 bytes")
        }

        guard let pointS = EdPoint.decode([UInt8](serverMsg)) else {
            throw SPAKE2Error.invalidMessage("Failed to decode server point")
        }

        // Compute K = x · (S - w·N)
        guard let N = EdPoint.N else {
            throw SPAKE2Error.invalidMessage("Failed to decode SPAKE2 N constant")
        }
        let wN = N.scalarMult(wScalar)
        let sMinusWN = pointS.add(wN.negate())
        let pointK = sMinusWN.scalarMult(x)

        guard !pointK.isIdentity else {
            throw SPAKE2Error.invalidMessage("Shared secret is identity point")
        }

        let kEncoded = pointK.encode()

        // Build transcript using SHA-512, matching BoringSSL's format:
        // For alice: update(my_name) || update(their_name) || update(my_msg) || update(their_msg) || update(K) || update(password_hash)
        // Each field is: len(8 LE) || data
        // Both sides produce canonical order: alice_name, bob_name, alice_msg, bob_msg, K, password_hash
        var sha = SHA512()

        // Alice's name (client) = our name
        updateWithLengthPrefix(&sha, Self.clientName)
        // Bob's name (server) = their name
        updateWithLengthPrefix(&sha, Self.serverName)
        // Alice's message (T) = our message
        updateWithLengthPrefix(&sha, outgoingMessage)
        // Bob's message (S) = their message
        updateWithLengthPrefix(&sha, serverMsg)
        // Shared secret K
        updateWithLengthPrefix(&sha, Data(kEncoded))
        // Password hash (full 64-byte SHA-512 of raw password)
        updateWithLengthPrefix(&sha, Data(passwordHash))

        let digest = sha.finalize()
        return Data(digest) // 64 bytes
    }

    /// Update SHA-512 with length-prefixed data (8-byte LE length + data).
    /// Matches BoringSSL's update_with_length_prefix.
    private func updateWithLengthPrefix<H: HashFunction>(_ hasher: inout H, _ data: Data) {
        var len = UInt64(data.count).littleEndian
        withUnsafeBytes(of: &len) { hasher.update(bufferPointer: $0) }
        hasher.update(data: data)
    }

    /// Multiply a 32-byte LE scalar by 8 (left shift by 3 bits).
    /// BoringSSL applies this to the private scalar for cofactor clearing.
    private static func leftShift3(_ scalar: inout [UInt8]) {
        var carry: UInt8 = 0
        for i in 0..<scalar.count {
            let newCarry = scalar[i] >> 5
            scalar[i] = (scalar[i] << 3) | carry
            carry = newCarry
        }
    }

    // MARK: - Scalar mod l reduction

    /// Reduce a 64-byte little-endian value modulo the group order l.
    /// BoringSSL's x25519_sc_reduce treats SHA-512 output as little-endian.
    /// Returns 32 bytes little-endian.
    static let order: [UInt8] = [0xed,0xd3,0xf5,0x5c,0x1a,0x63,0x12,0x58,0xd6,0x9c,0xf7,0xa2,0xde,0xf9,0xde,0x14] + Array(repeating: 0, count: 15) + [0x10]

    /// Fixed iteration reduction; no secret-dependent loop counts or table indices.
    static func reduceModL(_ input: [UInt8]) -> [UInt8] {
        precondition(input.count == 64)
        var remainder = [UInt8](repeating: 0, count: 32)
        for bit in stride(from: 511, through: 0, by: -1) {
            var carry = (input[bit / 8] >> (bit % 8)) & 1
            for i in 0..<32 {
                let next = remainder[i] >> 7
                remainder[i] = (remainder[i] << 1) | carry
                carry = next
            }
            var reduced = [UInt8](repeating: 0, count: 32)
            var borrow: Int16 = 0
            for i in 0..<32 {
                let difference = Int16(remainder[i]) - Int16(order[i]) - borrow
                reduced[i] = UInt8(truncatingIfNeeded: difference)
                borrow = (difference >> 15) & 1
            }
            let mask = UInt8(truncatingIfNeeded: borrow - 1)
            for i in 0..<32 { remainder[i] = (reduced[i] & mask) | (remainder[i] & ~mask) }
        }
        return remainder
    }

    /// Add multiples of the group order until divisible by eight. This is the
    /// BoringSSL cofactor correction; simply reducing leaks low password bits.
    static func passwordScalar(_ hash: [UInt8]) -> [UInt8] {
        var scalar = reduceModL(hash)
        var multiple = order
        for bit in 0..<3 {
            let mask = UInt8(0) &- ((scalar[0] >> bit) & 1)
            var carry: UInt16 = 0
            for i in 0..<32 {
                let sum = UInt16(scalar[i]) + UInt16(multiple[i] & mask) + carry
                scalar[i] = UInt8(truncatingIfNeeded: sum); carry = sum >> 8
            }
            var shiftCarry: UInt8 = 0
            for i in 0..<32 {
                let next = multiple[i] >> 7
                multiple[i] = (multiple[i] << 1) | shiftCarry; shiftCarry = next
            }
        }
        return scalar
    }

    enum SPAKE2Error: LocalizedError {
        case randomGenerationFailed
        case invalidMessage(String)

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed: return String(localized: "Failed to generate random bytes")
            case .invalidMessage(let m): return String(localized: "SPAKE2 error: \(m)")
            }
        }
    }
}

