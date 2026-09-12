import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Authenticated pairing fixtures. The short code is a SAS from a transcript
/// MAC, not a cipher and not an encryption key.
public enum PairingLimits: Sendable {
    public static let expirySeconds: TimeInterval = 120
    public static let maxFailedAttempts = 5
    public static let codeDigits = 6
    public static let identityByteCount = 32
    public static let sessionNonceByteCount = 16
    public static let sasInfo = "screenpunk-pairing-sas-v1"
}

public enum PairingRole: String, Sendable, Codable, Equatable {
    case device
    case controller
}

public struct PairingIdentity: Sendable, Equatable, Codable {
    public var role: PairingRole
    public var publicKey: [UInt8]

    public init(role: PairingRole, publicKey: [UInt8]) {
        self.role = role
        self.publicKey = publicKey
    }

    public var isWellFormed: Bool {
        publicKey.count == PairingLimits.identityByteCount
    }
}

public struct PairingTranscript: Sendable, Equatable, Codable {
    public var devicePublicKey: [UInt8]
    public var controllerPublicKey: [UInt8]
    public var sessionNonce: [UInt8]

    public init(devicePublicKey: [UInt8], controllerPublicKey: [UInt8], sessionNonce: [UInt8]) {
        self.devicePublicKey = devicePublicKey
        self.controllerPublicKey = controllerPublicKey
        self.sessionNonce = sessionNonce
    }

    public var canonicalBytes: [UInt8] {
        devicePublicKey + [0] + controllerPublicKey + [0] + sessionNonce
    }
}

public enum PairingFailure: String, Error, Sendable, Equatable {
    case expired
    case rateLimited
    case codeMismatch
    case identityChanged
    case secondOwner
    case invalidIdentity
}

public protocol PairingClock: Sendable {
    var now: Date { get }
}

public struct FixedClock: PairingClock, Sendable {
    public var now: Date
    public init(_ now: Date) { self.now = now }
}

#if canImport(CryptoKit)
public enum PairingSAS: Sendable {
    /// HMAC-SHA256(key: sasInfo, data: device || 0x00 || controller || 0x00 || session)
    /// then first 4 bytes as a 6-digit decimal. Standard MAC, not a home-grown cipher.
    public static func matchingCode(for transcript: PairingTranscript) -> String {
        let key = SymmetricKey(data: Data(PairingLimits.sasInfo.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(transcript.canonicalBytes),
            using: key
        )
        let bytes = Array(mac)
        let raw = (UInt32(bytes[0]) << 24)
            | (UInt32(bytes[1]) << 16)
            | (UInt32(bytes[2]) << 8)
            | UInt32(bytes[3])
        return String(format: "%0\(PairingLimits.codeDigits)d", raw % 1_000_000)
    }
}
#endif

public struct PairingSession: Sendable, Equatable {
    public var transcript: PairingTranscript
    public var expectedCode: String
    public var createdAt: Date
    public var failures: Int
    public var confirmed: Bool
    public var candidateOwner: PairingIdentity

    public init(
        transcript: PairingTranscript,
        expectedCode: String,
        createdAt: Date,
        candidateOwner: PairingIdentity,
        failures: Int = 0,
        confirmed: Bool = false
    ) {
        self.transcript = transcript
        self.expectedCode = expectedCode
        self.createdAt = createdAt
        self.candidateOwner = candidateOwner
        self.failures = failures
        self.confirmed = confirmed
    }
}

/// One owning controller identity per device. No credentials are stored here.
public struct DevicePairingState: Sendable, Equatable {
    public var owner: PairingIdentity?
    public var session: PairingSession?

    public init(owner: PairingIdentity? = nil, session: PairingSession? = nil) {
        self.owner = owner
        self.session = session
    }

    public mutating func begin(
        transcript: PairingTranscript,
        expectedCode: String,
        candidateOwner: PairingIdentity,
        clock: PairingClock
    ) throws {
        guard candidateOwner.role == .controller, candidateOwner.isWellFormed else {
            throw PairingFailure.invalidIdentity
        }
        if let owner, owner != candidateOwner {
            throw PairingFailure.secondOwner
        }
        session = PairingSession(
            transcript: transcript,
            expectedCode: expectedCode,
            createdAt: clock.now,
            candidateOwner: candidateOwner
        )
    }

    public mutating func confirm(code: String, presentedOwner: PairingIdentity, clock: PairingClock) throws {
        guard var session else { throw PairingFailure.expired }
        if clock.now.timeIntervalSince(session.createdAt) > PairingLimits.expirySeconds {
            self.session = nil
            throw PairingFailure.expired
        }
        if session.failures >= PairingLimits.maxFailedAttempts {
            throw PairingFailure.rateLimited
        }
        if presentedOwner != session.candidateOwner {
            throw PairingFailure.identityChanged
        }
        if let owner, owner != presentedOwner {
            throw PairingFailure.secondOwner
        }
        if code != session.expectedCode {
            session.failures += 1
            self.session = session
            if session.failures >= PairingLimits.maxFailedAttempts {
                throw PairingFailure.rateLimited
            }
            throw PairingFailure.codeMismatch
        }
        owner = presentedOwner
        session.confirmed = true
        self.session = session
    }
}
