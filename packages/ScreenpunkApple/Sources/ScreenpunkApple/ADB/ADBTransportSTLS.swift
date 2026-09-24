// Adapted from h33h/iadb-ios (MIT). See Resources/ADB-LICENSE.txt.
import Foundation
import Security
import os

private final class ADBURLSessionDelegateProxy: NSObject,
    URLSessionDelegate,
    URLSessionTaskDelegate,
    URLSessionStreamDelegate {
    weak var owner: ADBTransportSTLS?

    init(owner: ADBTransportSTLS) {
        self.owner = owner
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        owner?.handleChallenge(challenge, completionHandler: completionHandler)
            ?? completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        owner?.handleChallenge(challenge, completionHandler: completionHandler)
            ?? completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

actor ADBTransportWriteSerializer {
    private var tail: Task<Void, Never>?

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Void, Error> {
            _ = await previous?.value
            try Task.checkCancellation()
            try await operation()
        }
        tail = Task { _ = try? await task.value }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

/// Transport for the `_adb-tls-connect` STLS flow:
/// plain TCP → plaintext CNXN → STLS exchange → TLS upgrade → ADB packets.
final class ADBTransportSTLS: NSObject, @unchecked Sendable, ADBClientTransport {
    static let log = Logger(subsystem: "xyz.screenpunk.adb", category: "stls")

    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private let identity: SecIdentity
    private let expectedPin: Data?
    private var observedPin: Data?
    private var authenticationFailure: String?
    private var cancelledByOwner = false
    var serverPin: Data? { stateLock.withLock { observedPin } }
    private lazy var delegateProxy = ADBURLSessionDelegateProxy(owner: self)
    private let stateLock = NSLock()
    private let writeSerializer = ADBTransportWriteSerializer()
    private var receiveBuffer = Data()
    private var connectionAlive = false
    private(set) var isUpgraded = false

    var skipChecksum = false

    var isConnected: Bool {
        stateLock.withLock { connectionAlive && task?.state == .running }
    }

    init(identity: SecIdentity, expectedPin: Data?) {
        self.identity = identity
        self.expectedPin = expectedPin
        super.init()
    }

    deinit {
        let resources = stateLock.withLock { (task, session) }
        resources.0?.cancel()
        resources.1?.invalidateAndCancel()
    }

    func connect(host: String, port: UInt16, timeout: TimeInterval = 15) async throws {
        disconnect()
        try Task.checkCancellation()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 60)
        let session = URLSession(
            configuration: configuration,
            delegate: delegateProxy,
            delegateQueue: nil
        )
        let task = session.streamTask(withHostName: host, port: Int(port))
        stateLock.withLock {
            self.session = session
            self.task = task
            self.connectionAlive = true
            self.cancelledByOwner = false
            self.authenticationFailure = nil
            self.observedPin = nil
        }
        task.resume()
        Self.log.info("STLS: TCP connect endpoint=\(host, privacy: .private(mask: .hash))")
    }

    /// Upgrade the already-open TCP stream to mutual TLS.
    func upgradeToTLS() async throws {
        guard let task = stateLock.withLock({ task }) else {
            throw ADBError.notConnected
        }
        try Task.checkCancellation()
        Self.log.info("STLS: starting TLS upgrade")
        task.startSecureConnection()
        stateLock.withLock {
            isUpgraded = true
            skipChecksum = true
        }
        // URLSessionStreamTask has no async TLS-ready callback. The first
        // encrypted read/write still drives and validates the handshake.
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    func disconnect() {
        let resources = stateLock.withLock { () -> (URLSessionStreamTask?, URLSession?) in
            let resources = (task, session)
            task = nil
            session = nil
            receiveBuffer.removeAll(keepingCapacity: false)
            connectionAlive = false
            cancelledByOwner = true
            skipChecksum = false
            isUpgraded = false
            return resources
        }
        resources.0?.cancel()
        resources.1?.invalidateAndCancel()
    }

    func send(_ data: Data) async throws {
        guard let task = stateLock.withLock({ task }) else {
            throw ADBError.notConnected
        }

        try await writeSerializer.run {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    task.write(data, timeout: 30) { error in
                        if let error {
                            self.markConnectionFailed()
                            continuation.resume(throwing: self.reportedError(error))
                        } else {
                            continuation.resume()
                        }
                    }
                }
            } onCancel: {
                self.stateLock.withLock { self.cancelledByOwner = true }
                task.cancel()
            }
        }
    }

    func sendMessage(_ message: ADBMessage) async throws {
        try await send(message.serialized)
    }

    func receiveMessage(timeout: TimeInterval? = nil) async throws -> ADBMessage {
        do {
            if let timeout {
                return try await withTimeout(timeout) {
                    try await self.receiveMessageWithoutTimeout()
                }
            }
            return try await receiveMessageWithoutTimeout()
        } catch {
            if !(error is CancellationError) {
                // A framing/checksum/read failure poisons the multiplexed byte
                // stream. Make health monitoring observe the loss instead of
                // leaving the app in a permanently unusable “Connected” state.
                markConnectionFailed()
            }
            throw error
        }
    }

    private func receiveMessageWithoutTimeout() async throws -> ADBMessage {
        let headerData = try await receive(exactly: ADBMessage.headerSize)

        guard let header = ADBMessage.parseHeader(from: headerData) else {
            throw ADBError.protocolError("Invalid message header")
        }

        let commandName = String(bytes: [
            UInt8(header.command & 0xFF),
            UInt8((header.command >> 8) & 0xFF),
            UInt8((header.command >> 16) & 0xFF),
            UInt8((header.command >> 24) & 0xFF)
        ], encoding: .ascii) ?? "?"
        Self.log.debug(
            "STLS header command=\(commandName, privacy: .private) length=\(header.dataLength, privacy: .private)"
        )

        guard header.command ^ header.magic == 0xFFFFFFFF else {
            Self.log.error("STLS received a header with invalid magic")
            throw ADBError.protocolError(
                "Bad header magic: cmd=\(String(format: "0x%08X", header.command)) "
                    + "magic=\(String(format: "0x%08X", header.magic))"
            )
        }

        var payload = Data()
        if header.dataLength > 0 {
            guard header.dataLength <= ADBMessage.maxPayload else {
                Self.log.error("STLS payload exceeds negotiated maximum")
                throw ADBError.protocolError("Payload too large: \(header.dataLength)")
            }
            payload = try await receive(exactly: Int(header.dataLength))
        }

        let message = ADBMessage(
            command: header.command,
            arg0: header.arg0,
            arg1: header.arg1,
            dataLength: header.dataLength,
            dataCRC32: header.dataCRC32,
            magic: header.magic,
            data: payload
        )

        let shouldSkipChecksum = stateLock.withLock { skipChecksum }
        guard message.isValid(skipChecksum: shouldSkipChecksum) else {
            throw ADBError.protocolError("Message validation failed")
        }

        if message.commandType == .connect && message.arg0 >= ADBMessage.version {
            stateLock.withLock { skipChecksum = true }
        }
        return message
    }

    private func receive(exactly count: Int) async throws -> Data {
        guard count >= 0 else {
            throw ADBError.protocolError("Negative receive length")
        }

        while true {
            try Task.checkCancellation()
            if let buffered = stateLock.withLock({ () -> Data? in
                guard receiveBuffer.count >= count else { return nil }
                let result = Data(receiveBuffer.prefix(count))
                receiveBuffer.removeFirst(count)
                return result
            }) {
                return buffered
            }

            guard let task = stateLock.withLock({ task }) else {
                throw ADBError.notConnected
            }
            let result: (data: Data?, atEOF: Bool) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    // Zero disables URLSessionStreamTask's per-read idle timeout.
                    // Callers that need a deadline use receiveMessage(timeout:).
                    task.readData(ofMinLength: 1, maxLength: 65_536, timeout: 0) { data, atEOF, error in
                        if let error {
                            self.markConnectionFailed()
                            continuation.resume(throwing: self.reportedError(error))
                        } else {
                            continuation.resume(returning: (data, atEOF))
                        }
                    }
                }
            } onCancel: {
                // URLSessionStreamTask has no API to cancel one pending read.
                // Cancelling the socket is the only way to release its callback.
                self.stateLock.withLock { self.cancelledByOwner = true }
                task.cancel()
            }

            if let data = result.data, !data.isEmpty {
                stateLock.withLock { receiveBuffer.append(data) }
            }
            if result.atEOF {
                let hasEnoughData = stateLock.withLock { receiveBuffer.count >= count }
                if !hasEnoughData {
                    markConnectionFailed()
                    throw ADBError.connectionClosed
                }
            }
        }
    }

    private func reportedError(_ error: Error) -> Error {
        let state = stateLock.withLock { (authenticationFailure, cancelledByOwner) }
        return Self.diagnosticError(error, authenticationFailure: state.0, cancelledByOwner: state.1)
    }

    static func diagnosticError(_ error: Error, authenticationFailure: String?, cancelledByOwner: Bool) -> Error {
        if let failure = authenticationFailure { return ADBError.connectionFailed(failure) }
        if cancelledByOwner { return CancellationError() }
        if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
            return ADBError.connectionFailed("TLS negotiation was rejected. Check the TV's current wireless debugging connection port and paired-device entry. This was not a user cancellation.")
        }
        return ADBError.connectionFailed(error.localizedDescription)
    }

    private func markConnectionFailed() {
        stateLock.withLock { connectionAlive = false }
    }

    private func withTimeout<T: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard timeout > 0 else { throw ADBError.timeout }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw ADBError.timeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw ADBError.timeout
            }
            return result
        }
    }

    fileprivate func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        Self.log.debug("STLS authentication challenge: \(method, privacy: .private)")

        switch method {
        case NSURLAuthenticationMethodServerTrust:
            // adbd uses a self-signed device certificate.
            if let trust = challenge.protectionSpace.serverTrust,
               let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
               let certificate = certificates.first {
                guard let pin = try? GoogleTVADBTrust.pin(certificate: certificate) else {
                    stateLock.withLock { authenticationFailure = "The TV did not provide a usable public key." }
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                guard expectedPin == nil || expectedPin == pin else {
                    stateLock.withLock { authenticationFailure = "The TV debugging key changed. On your trusted home network, confirm the TV address and use Refresh TV Trust. Existing pairing is preserved." }
                    completionHandler(.cancelAuthenticationChallenge, nil); return
                }
                stateLock.withLock { observedPin = pin }
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                stateLock.withLock { authenticationFailure = "The TV TLS certificate is unavailable." }
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            var certificate: SecCertificate?
            SecIdentityCopyCertificate(identity, &certificate)
            guard let certificate else {
                stateLock.withLock { authenticationFailure = "The saved Screenpunk identity certificate is unavailable. Pairing credentials were preserved." }
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(identity: identity, certificates: [certificate], persistence: .none)
            )
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
