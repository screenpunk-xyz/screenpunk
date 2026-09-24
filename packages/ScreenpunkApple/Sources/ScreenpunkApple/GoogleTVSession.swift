import Foundation
import Network
import Security
import CryptoKit
import OSLog

public enum GoogleTVError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

private final class GoogleTVPeer: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; key = value }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return key }
}

/// One session, no replay of commands after a network failure. All mutable
/// protocol state is confined to the main actor; Keychain signing runs elsewhere.
@MainActor
final class GoogleTVSession {
    private typealias W = GoogleTVWire
    private var connection: NWConnection?
    // Injectable framed transport for protocol tests; production always uses pinned TLS.
    private let transportOverride: ((Data, @escaping (Error?) -> Void) -> Void)?
    private let sleep: (UInt64) async throws -> Void
    private var voiceEndDelay: Task<Void, Error>?
    init(sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         transport: ((Data, @escaping (Error?) -> Void) -> Void)? = nil) {
        self.sleep = sleep; transportOverride = transport
    }
    private static let voiceLog = Logger(subsystem: "xyz.screenpunk", category: "GoogleTVVoice")
    private var framer = W.Framer()
    private var peer = GoogleTVPeer()
    private var material: GoogleTVIdentity?
    private var waiter: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var epoch = UUID()
    private var pairingStep = 0
    private var features: UInt64 = 0
    private static var commandBusy = false
    private var voiceStarting = false
    private var voiceID: UInt64?
    private(set) var ready = false
    private(set) var status: [String: Any] = ["connected": false]

    deinit { connection?.cancel(); deadline?.cancel(); idle?.cancel(); voiceEndDelay?.cancel() }

    func close(_ error: Error = GoogleTVError.message("Google TV connection closed.")) {
        voiceStarting = false; voiceID = nil
        voiceEndDelay?.cancel(); voiceEndDelay = nil
        epoch = UUID(); ready = false; status = ["connected": false]
        deadline?.cancel(); deadline = nil; idle?.cancel(); idle = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        let pending = waiter; waiter = nil; pending?.resume(throwing: error)
    }
    func beginPairing(host: String) async throws {
        try await start(host: host, pin: nil, pairing: true)
    }
    func finishPairing(code: String) async throws -> Data {
        guard pairingStep == 3, let material, let publicKey = peer.get() else { throw GoogleTVError.message("Start pairing again.") }
        let secret = try GoogleTVIdentity.secret(client: material.publicKey, server: publicKey, code: code)
        pairingStep = 4
        try await waitForEvent(timeout: 10) { self.send(Self.pair(40, W.bytes(1, secret))) }
        let pin = Data(SHA256.hash(data: publicKey)); close(); return pin
    }
    func connect(host: String, pin: Data) async throws {
        if ready { return }
        guard pin.count == 32 else { throw GoogleTVError.message("Pair this TV in native connection settings first.") }
        try await start(host: host, pin: pin, pairing: false)
    }
    private func start(host: String, pin: Data?, pairing: Bool) async throws {
        close(); let generation = epoch
        let identity = try await Task.detached { try GoogleTVIdentity.loadOrCreate() }.value
        try Task.checkCancellation()
        guard epoch == generation else { throw CancellationError() }
        material = identity; peer = GoogleTVPeer(); framer = W.Framer(); pairingStep = pairing ? 1 : 0
        guard let nativeIdentity = sec_identity_create(identity.identity) else { throw GoogleTVError.message("Google TV identity unavailable.") }
        let options = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(options.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_local_identity(options.securityProtocolOptions, nativeIdentity)
        let peer = self.peer
        sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
            let trust = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
                  let key = SecCertificateCopyKey(cert), let data = SecKeyCopyExternalRepresentation(key, nil) as Data?,
                  (try? GoogleTVIdentity.rsaComponents(data)) != nil else { complete(false); return }
            peer.set(data)
            // An unpinned peer is permitted only during explicit PIN pairing.
            complete(pin.map { Data(SHA256.hash(data: data)) == $0 } ?? pairing)
        }, DispatchQueue.global(qos: .userInitiated))
        let tcp = NWProtocolTCP.Options(); tcp.connectionTimeout = 8
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: pairing ? 6467 : 6466)!, using: NWParameters(tls: options, tcp: tcp))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                switch state {
                case .ready:
                    self.receive(generation)
                    if pairing { self.send(Self.pair(10, W.string(1, "atvremote") + W.string(2, "Screenpunk"))) }
                case .failed, .waiting:
                    self.close(GoogleTVError.message("Cannot reach the paired Google TV. Check Wi-Fi, Local Network permission, and the TV's Remote Service."))
                default: break
                }
            }
        }
        try await waitForEvent(timeout: 12) { connection.start(queue: DispatchQueue.global(qos: .userInitiated)) }
    }
    private func waitForEvent(timeout: Double, begin: () -> Void) async throws {
        guard waiter == nil else { throw GoogleTVError.message("Google TV is busy. Try again.") }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); try Task.checkCancellation() } catch { return }
                    self?.close(GoogleTVError.message("Google TV did not respond in time. Check the TV and try again."))
                }
                begin()
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.close(CancellationError()) } })
    }
    private func complete() { deadline?.cancel(); deadline = nil; let pending = waiter; waiter = nil; pending?.resume() }
    private static func pair(_ field: Int, _ payload: Data) -> Data { W.number(1, 2) + W.number(2, 200) + W.bytes(field, payload) }
    private func send(_ payload: Data) {
        let generation = epoch
        write(payload) { [weak self] error in
            if error != nil { Task { @MainActor in if self?.epoch == generation { self?.close(GoogleTVError.message("Google TV connection was lost.")) } } }
        }
    }
    private func receive(_ generation: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: W.limit) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, self.epoch == generation else { return }
                guard error == nil, !done, let data, !data.isEmpty else { self.close(); return }
                do { for frame in try self.framer.append(data) { try self.handle(W.parse(frame)) } }
                catch { self.close(GoogleTVError.message("Google TV sent an invalid protocol response.")); return }
                guard self.epoch == generation else { return }
                self.idle?.cancel()
                // Leave enough time to read the on-TV PIN; regular sessions expect pings.
                let timeout: UInt64 = self.pairingStep == 3 ? 120 : 20
                self.idle = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: timeout * 1_000_000_000); try Task.checkCancellation() } catch { return }; self?.close()
                }
                self.receive(generation)
            }
        }
    }
    func handle(_ message: GoogleTVWire.Message) throws {
        if pairingStep > 0 {
            guard message.numbers[2] == 200 else { close(GoogleTVError.message("Google TV rejected pairing. Start again and enter the current TV code.")); return }
            let encoding = W.number(1, 3) + W.number(2, 6)
            if pairingStep == 1, message.payloads[11] != nil { pairingStep = 2; send(Self.pair(20, W.bytes(1, encoding) + W.number(3, 1))) }
            else if pairingStep == 2, message.payloads[20] != nil { send(Self.pair(30, W.bytes(1, encoding) + W.number(2, 1))) }
            else if pairingStep == 2, message.payloads[31] != nil { pairingStep = 3; complete() }
            else if pairingStep == 4, message.payloads[41] != nil { complete() }
            return
        }
        if message.payloads[1] != nil {
            let config = try message.nested(1); features = (config.numbers[1] ?? 0) & 623
            status["voiceSupported"] = features & 8 != 0
            let info = W.number(3, 1) + W.string(4, "1") + W.string(5, "xyz.screenpunk") + W.string(6, "0.2")
            send(W.bytes(1, W.number(1, features) + W.bytes(2, info)))
        }
        if message.payloads[2] != nil { send(W.bytes(2, W.number(1, features))) }
        if message.payloads[8] != nil { send(W.bytes(9, W.number(1, try message.nested(8).numbers[1] ?? 0))) }
        if message.payloads[40] != nil {
            let wasReady = ready
            ready = true; status["connected"] = true; status["streamerAwake"] = (try message.nested(40).numbers[1] ?? 0) != 0
            status["tvPower"] = "unknown"; status["playingChannel"] = "unknown"; if !wasReady { complete() }
        }
        if message.payloads[20] != nil, let app = try message.nested(20).nested(1).payloads[12] { status["currentApp"] = String(data: app, encoding: .utf8) ?? "" }
        if message.payloads[50] != nil {
            let volume = try message.nested(50)
            status["streamerVolume"] = volume.numbers[7] ?? 0; status["streamerVolumeMax"] = volume.numbers[6] ?? 0; status["streamerMuted"] = (volume.numbers[8] ?? 0) != 0
        }
        if message.payloads[30] != nil, voiceStarting {
            let begin = try message.nested(30)
            voiceID = begin.numbers[1] ?? 0 // proto3 zero-valued session IDs are valid.
            voiceStarting = false; complete()
        }
        if message.payloads[32] != nil, voiceID != nil { close(GoogleTVError.message("TV ended the voice session before delivery completed.")) }
        if message.payloads[3] != nil { close(GoogleTVError.message("Google TV reported a remote-control error.")) }
    }
    @discardableResult
    func voice(audio: Data, authorize: () throws -> Void = {}) async throws -> [String: Any] {
        guard !Self.commandBusy else { throw GoogleTVError.message("Google TV is busy.") }
        Self.commandBusy = true; defer { Self.commandBusy = false }
        try authorize()
        let chunks = try GoogleTVAudio.chunks(audio)
        guard ready, features & 10 == 10, voiceID == nil, !voiceStarting else {
            throw GoogleTVError.message("TV remote service does not support voice or is busy.")
        }
        try Task.checkCancellation()
        let token = epoch
        let metrics = GoogleTVAudio.metrics(audio)
        let started = ProcessInfo.processInfo.systemUptime
        var deliveredBytes = 0; var deliveredPackets = 0
        var phase = "readiness"
        Self.voiceLog.notice("Voice start: frames=\(audio.count / 2) peak=\(metrics.peak) rms=\(metrics.rms) nonzero=\(metrics.nonzero) packets=\(chunks.count)")
        do {
            voiceStarting = true
            try await waitForEvent(timeout: 3) { send(W.bytes(10, W.number(1, 84) + W.number(2, 3))) }
            guard epoch == token, let id = voiceID else { throw CancellationError() }
            try authorize()
            phase = "begin"
            Self.voiceLog.notice("Voice ready after \(ProcessInfo.processInfo.systemUptime - started)s; TV session ID accepted")
            try await transmit(W.bytes(30, W.number(1, id)))
            let streamStarted = ProcessInfo.processInfo.systemUptime
            phase = "audio"
            for chunk in chunks {
                try authorize()
                try Task.checkCancellation()
                guard epoch == token, voiceID == id else { throw CancellationError() }
                try await transmit(W.bytes(31, W.number(1, id) + W.bytes(2, chunk)))
                deliveredBytes += chunk.count; deliveredPackets += 1
                Self.voiceLog.notice("Voice packet \(deliveredPackets): bytes=\(chunk.count) elapsed=\(ProcessInfo.processInfo.systemUptime - streamStarted)s")
                try authorize()
                guard epoch == token, voiceID == id else { throw CancellationError() }
            }
            // Experiment isolates end timing: preserve the exact reference packet
            // bytes and burst writes, but keep the session open for the PCM duration.
            // Socket completion is not receiver consumption. No per-packet pacing.
            phase = "endHold"
            let holdNanoseconds = UInt64(deliveredBytes) * 1_000_000_000 / UInt64(GoogleTVAudio.bytesPerSecond)
            Self.voiceLog.notice("Voice end hold: bytes=\(deliveredBytes) duration=\(Double(holdNanoseconds) / 1_000_000_000)s")
            try await holdVoiceEnd(nanoseconds: holdNanoseconds)
            try authorize()
            try Task.checkCancellation()
            guard epoch == token, voiceID == id else { throw CancellationError() }
            phase = "end"
            try await transmit(W.bytes(32, W.number(1, id)))
            Self.voiceLog.notice("Voice delivered: packets=\(deliveredPackets) bytes=\(deliveredBytes) elapsed=\(ProcessInfo.processInfo.systemUptime - streamStarted)s; recognition unverified")
            voiceID = nil
            return ["sent": true, "effectVerified": false,
                    "audioSeconds": Double(audio.count) / Double(GoogleTVAudio.bytesPerSecond),
                    "streamSeconds": ProcessInfo.processInfo.systemUptime - streamStarted,
                    "streamedPCMSeconds": Double(chunks.reduce(0) { $0 + $1.count }) / Double(GoogleTVAudio.bytesPerSecond),
                    "endHoldSeconds": Double(holdNanoseconds) / 1_000_000_000,
                    "audioPackets": chunks.count, "pcmPeak": metrics.peak, "pcmRMS": metrics.rms, "pcmNonzeroFrames": metrics.nonzero]
        } catch {
            Self.voiceLog.error("Voice failed: phase=\(phase, privacy: .public) packets=\(deliveredPackets) bytes=\(deliveredBytes) elapsed=\(ProcessInfo.processInfo.systemUptime - started)s error=\(error.localizedDescription, privacy: .private)")
            // Closing TLS aborts unfinished audio; never replay or send a partial utterance again.
            close(error); throw error
        }
    }
    private func holdVoiceEnd(nanoseconds: UInt64) async throws {
        let delay = Task { try await sleep(nanoseconds) }
        voiceEndDelay = delay
        defer { voiceEndDelay = nil }
        try await withTaskCancellationHandler(operation: {
            try await delay.value
            try Task.checkCancellation()
        }, onCancel: { delay.cancel() })
    }
    private func write(_ payload: Data, completion: @escaping (Error?) -> Void) {
        let framed = W.varint(UInt64(payload.count)) + payload
        if let transportOverride { transportOverride(framed, completion) }
        else { connection?.send(content: framed, completion: .contentProcessed { completion($0) }) }
    }
    private func transmit(_ payload: Data) async throws {
        guard ready, connection != nil || transportOverride != nil else { throw GoogleTVError.message("Google TV disconnected.") }
        try Task.checkCancellation()
        let token = epoch
        try await waitForEvent(timeout: 5) {
            write(payload) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.epoch == token else { return }
                    if let error { self.close(error) } else { self.complete() }
                }
            }
        }
    }
    static let keys: [String: UInt64] = ["wake": 224, "sleep": 223, "tvPowerToggle": 177, "volumeUp": 24, "volumeDown": 25, "muteToggle": 164, "home": 3, "back": 4, "up": 19, "down": 20, "left": 21, "right": 22, "select": 23, "playPause": 85]
    func command(key: String?, link: String?) async throws {
        guard !Self.commandBusy else { throw GoogleTVError.message("Google TV is busy.") }
        Self.commandBusy = true; defer { Self.commandBusy = false }
        guard ready, connection != nil || transportOverride != nil else { throw GoogleTVError.message("Google TV is not connected.") }
        let payload: Data
        if let key, let code = Self.keys[key], features & 2 != 0 { payload = W.bytes(10, W.number(1, code) + W.number(2, 3)) }
        else if let link, features & 512 != 0 { payload = W.bytes(90, W.string(1, link)) }
        else { throw GoogleTVError.message("This control is not supported by the TV remote service.") }
        try Task.checkCancellation()
        // contentProcessed confirms transport delivery, not visible TV behavior.
        let generation = epoch
        try await waitForEvent(timeout: 5) {
            write(payload) { [weak self] error in
                Task { @MainActor in
                    guard let self, self.epoch == generation else { return }
                    if let error { self.close(error) } else { self.complete() }
                }
            }
        }
    }
}
