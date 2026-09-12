import Foundation
import ScreenpunkCore
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif

#if canImport(Network) && canImport(Security)
enum LANChannel {
    /// TLS 1.3 + mutual identity only. Never falls back to plaintext TCP.
    static func tlsParameters(
        identity: TLSIdentityMaterial,
        pinnedPeer: @escaping () -> [UInt8]?,
        queue: DispatchQueue
    ) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity.identity) else {
            throw TransferFailure.validationFailed
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let pin = TLSIdentity.pin(from: secTrust)
            if let expected = pinnedPeer() {
                complete(pin == expected)
            } else {
                complete(pin != nil)
            }
        }, queue)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = true
        return parameters
    }

    /// SHA-256 pin of the leaf certificate the peer actually presented during
    /// this connection's TLS handshake. Nil before `.ready` or when the peer
    /// sent no certificate. Both sides bind the SAS transcript to this value,
    /// never to a pin the peer merely claims in a message.
    static func observedPeerPin(_ connection: NWConnection) -> [UInt8]? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        var pin: [UInt8]?
        let visited = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard pin == nil else { return }
            let ref = sec_certificate_copy_ref(certificate).takeRetainedValue()
            guard let key = SecCertificateCopyKey(ref),
                  let data = SecKeyCopyExternalRepresentation(key, nil) as Data?
            else {
                return
            }
            pin = PeerPin.sha256(data)
        }
        return visited ? pin : nil
    }
}

final class LANLink {
    private let connection: NWConnection

    init(connection: NWConnection, queue _: DispatchQueue) {
        self.connection = connection
    }

    func send(_ envelope: LANEnvelope, timeout: TimeInterval = 15) throws {
        let framed = try LANCodec.frame(try LANCodec.encode(envelope))
        let done = DispatchSemaphore(value: 0)
        var sendError: Error?
        connection.send(content: framed, completion: .contentProcessed { error in
            sendError = error
            done.signal()
        })
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw TransferFailure.interrupted
        }
        if sendError != nil {
            throw TransferFailure.interrupted
        }
    }

    func receive(timeout: TimeInterval = 15) throws -> LANEnvelope {
        let header = try receiveExact(4, timeout: timeout)
        let length = try LANCodec.messageLength(fromHeader: header)
        let body = try receiveExact(length, timeout: timeout)
        return try LANCodec.decode(body)
    }

    private func receiveExact(_ count: Int, timeout: TimeInterval) throws -> Data {
        let done = DispatchSemaphore(value: 0)
        var result: Result<Data, Error> = .failure(TransferFailure.interrupted)
        connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            if let error {
                result = .failure(error)
            } else if let data, data.count == count {
                result = .success(data)
            } else {
                result = .failure(TransferFailure.interrupted)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            throw TransferFailure.interrupted
        }
        return try result.get()
    }
}
#endif
