import Foundation

protocol ADBClientTransport: Sendable {
    func connect(host: String, port: UInt16, timeout: TimeInterval) async throws
    func sendMessage(_ message: ADBMessage) async throws
    func receiveMessage(timeout: TimeInterval?) async throws -> ADBMessage
    func upgradeToTLS() async throws
    func disconnect()
}

protocol GoogleTVADBSession: Sendable {
    func connect(host: String, port: UInt16) async throws
    func launch(channelID: String) async throws
    func togglePower() async throws
    func close()
}

/// One short-lived connection and one fixed TV command; no shell API for screens.
final class GoogleTVADBClient: GoogleTVADBSession, @unchecked Sendable {
    private let transport: any ADBClientTransport
    init(pin: Data?) throws {
        transport = ADBTransportSTLS(identity: try ADBCrypto().tlsIdentity(), expectedPin: pin)
    }
    init(transport: any ADBClientTransport) { self.transport = transport }
    var serverPin: Data? { (transport as? ADBTransportSTLS)?.serverPin }
    func close() { transport.disconnect() }
    deinit { close() }

    func connect(host: String, port: UInt16) async throws {
        try await transport.connect(host: host, port: port, timeout: 15)
        try await transport.sendMessage(.connectMessage(banner: "host::features=shell_v2"))
        let start = try await transport.receiveMessage(timeout: 15)
        guard start.commandType == .stls, start.arg0 == ADBMessage.stlsVersion else {
            throw ADBError.protocolError("Use the wireless debugging connection port. Plaintext ADB is unsupported.")
        }
        try await transport.sendMessage(.stlsMessage())
        try await transport.upgradeToTLS()
        let ready = try await transport.receiveMessage(timeout: 15)
        guard ready.commandType == .connect,
              ready.dataString?.contains("shell_v2") == true else {
            throw ADBError.protocolError("Pair this device in wireless debugging before connecting.")
        }
    }

    func launch(channelID: String) async throws {
        let command = try GoogleTVChannelLaunch.command(channelID: channelID)
        try await execute(command, power: false)
    }
    func togglePower() async throws {
        try await execute("input keyevent 177", power: true)
    }
    private func execute(_ command: String, power: Bool) async throws {
        try Task.checkCancellation()
        try await transport.sendMessage(.openMessage(localId: 1, destination: "shell,v2,raw:" + command))
        let opened = try await transport.receiveMessage(timeout: 15)
        guard opened.commandType == .ready, opened.arg1 == 1, opened.arg0 != 0 else {
            throw ADBError.protocolError("TV refused the direct command service.")
        }
        let remote = opened.arg0
        var decoder = GoogleTVADBShellResult(power: power)
        while true {
            try Task.checkCancellation()
            let message = try await transport.receiveMessage(timeout: 15)
            guard message.arg1 == 1, message.arg0 == remote else { throw ADBError.protocolError("Unexpected ADB stream.") }
            guard message.commandType == .write else { throw ADBError.protocolError("TV command closed without confirmation. Check the TV before trying again.") }
            if try decoder.append(message.data) {
                try await transport.sendMessage(.readyMessage(localId: 1, remoteId: remote))
                try await transport.sendMessage(.closeMessage(localId: 1, remoteId: remote))
                return
            }
            try await transport.sendMessage(.readyMessage(localId: 1, remoteId: remote))
        }
    }
}

struct GoogleTVADBShellResult {
    private let power: Bool
    init(power: Bool = false) { self.power = power }
    private var buffer = Data()
    private var output = Data()
    mutating func append(_ data: Data) throws -> Bool {
        guard buffer.count + data.count <= 32_768 else { throw ADBError.protocolError("Channel response is too large.") }
        buffer.append(data)
        while buffer.count >= 5 {
            let id = buffer[buffer.startIndex]
            let length = buffer.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 1, as: UInt32.self).littleEndian) }
            guard length <= 16_384 else { throw ADBError.protocolError("Channel response is too large.") }
            guard buffer.count >= 5 + length else { return false }
            let payload = Data(buffer.dropFirst(5).prefix(length))
            buffer.removeFirst(5 + length)
            if id == 1 || id == 2 {
                guard output.count + payload.count <= 16_384 else { throw ADBError.protocolError("Channel response is too large.") }
                output.append(payload)
            } else if id == 3 {
                guard payload.count == 1 || payload.count == 4, buffer.isEmpty else { throw ADBError.protocolError("Invalid command result.") }
                let exit = payload.count == 1 ? Int(payload.first!) : payload.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self).littleEndian) }
                if power {
                    guard exit == 0, output.isEmpty else {
                        throw ADBError.protocolError("TV power command did not confirm completion. Check the TV before trying again.")
                    }
                } else {
                    try GoogleTVChannelLaunch.validateDispatch(exitCode: exit, output: String(decoding: output, as: UTF8.self))
                }
                return true
            } else { throw ADBError.protocolError("Unexpected command response.") }
        }
        return false
    }
}
