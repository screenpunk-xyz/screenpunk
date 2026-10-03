import Foundation

public enum CloudWorkspaceSetupOperationRecordError: Error, Equatable, Sendable {
    case invalidRecord, unsupportedVersion(Int), tooLarge, conflict
}

/// Local operation evidence only. A workspace receipt is never device-management authority.
public struct CloudWorkspaceSetupOperationRecord: Codable, Equatable, Sendable {
    public static let maximumBytes = 16 * 1024
    public let schemaVersion: Int
    public let userID: UUID
    public let request: CloudNativeWorkspaceSetupRequest
    public let receipt: CloudNativeWorkspaceSetupReceipt?
    public init(userID: UUID, request: CloudNativeWorkspaceSetupRequest, receipt: CloudNativeWorkspaceSetupReceipt? = nil) throws {
        try request.validate()
        guard receipt == nil || receipt?.requestId == request.requestId else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
        schemaVersion = 1; self.userID = userID; self.request = request; self.receipt = receipt
    }
    private enum Keys: String, CodingKey { case schemaVersion, userID, request, receipt }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: DynamicKey.self)
        guard Set(all.allKeys.map(\.stringValue)).isSubset(of: ["schemaVersion", "userID", "request", "receipt"]) else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
        let values = try decoder.container(keyedBy: Keys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else { throw CloudWorkspaceSetupOperationRecordError.unsupportedVersion(version) }
        try Self.checkNested(decoder: values.superDecoder(forKey: .request), keys: ["requestId", "workspaceName", "locationName"])
        if values.contains(.receipt), !(try values.decodeNil(forKey: .receipt)) {
            try Self.checkNested(decoder: values.superDecoder(forKey: .receipt), keys: ["requestId", "accountId", "locationId", "createdAt"])
        }
        try self.init(userID: values.decode(UUID.self, forKey: .userID), request: values.decode(CloudNativeWorkspaceSetupRequest.self, forKey: .request), receipt: values.decodeIfPresent(CloudNativeWorkspaceSetupReceipt.self, forKey: .receipt))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Keys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion); try values.encode(userID, forKey: .userID)
        try values.encode(request, forKey: .request); try values.encodeIfPresent(receipt, forKey: .receipt)
    }
    public func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw CloudWorkspaceSetupOperationRecordError.tooLarge }
        return bytes
    }
    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= maximumBytes else { throw CloudWorkspaceSetupOperationRecordError.tooLarge }
        try CloudWorkspaceStrictJSON.validate(bytes)
        do { return try JSONDecoder().decode(Self.self, from: bytes) }
        catch let error as CloudWorkspaceSetupOperationRecordError { throw error }
        catch { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
    }
    public func permits(_ next: Self, beginningSuccessor: Bool) -> Bool {
        if beginningSuccessor { return receipt != nil && next.receipt == nil && request.requestId != next.request.requestId }
        guard userID == next.userID, request == next.request else { return false }
        return self == next || (receipt == nil && next.receipt != nil)
    }
    private static func checkNested(decoder: Decoder, keys: Set<String>) throws {
        guard Set(try decoder.container(keyedBy: DynamicKey.self).allKeys.map(\.stringValue)) == keys else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
    }
    private struct DynamicKey: CodingKey {
        let stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil }
    }
}

// Detect duplicate keys and malformed UTF-16 escapes before Foundation collapses them.
private enum CloudWorkspaceStrictJSON {
    static func validate(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
        var parser = Parser(bytes: Array(data)); try parser.value(depth: 0); parser.space()
        guard parser.index == parser.bytes.count else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
    }
    private struct Parser {
        let bytes: [UInt8]; var index = 0; var nodes = 4096
        mutating func space() { while index < bytes.count && [9,10,13,32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) throws { guard index < bytes.count, bytes[index] == byte else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }; index += 1 }
        mutating func string() throws -> String {
            let start = index; try take(34)
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 34 {
                    let data = Data(bytes[start..<index]); let decoded = try JSONDecoder().decode(String.self, from: data)
                    // JSONDecoder substitutes lone surrogates on some SDKs: verify escape pairing ourselves.
                    return decoded
                }
                guard byte >= 32 else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                if byte == 92 {
                    guard index < bytes.count else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                    let escaped = bytes[index]; index += 1
                    if escaped == 117 {
                        let code = try hex()
                        if (0xD800...0xDBFF).contains(code) { try take(92); try take(117); let low = try hex(); guard (0xDC00...0xDFFF).contains(low) else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord } }
                        else if (0xDC00...0xDFFF).contains(code) { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                    } else if ![34,92,47,98,102,110,114,116].contains(escaped) { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                }
            }
            throw CloudWorkspaceSetupOperationRecordError.invalidRecord
        }
        mutating func hex() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard index < bytes.count, let digit = Int(String(UnicodeScalar(bytes[index])), radix: 16) else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                value = value * 16 + digit; index += 1
            }
            return value
        }
        mutating func value(depth: Int) throws {
            space(); nodes -= 1
            guard depth < 24, nodes >= 0, index < bytes.count else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
            if bytes[index] == 123 {
                index += 1; space(); var keys = Set<Data>()
                if index < bytes.count, bytes[index] == 125 { index += 1; return }
                while true {
                    space(); let key = try string()
                    guard keys.insert(Data(key.utf8)).inserted else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                    space(); try take(58); try value(depth: depth + 1); space()
                    guard index < bytes.count else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                    if bytes[index] == 125 { index += 1; return }; try take(44)
                }
            } else if bytes[index] == 91 {
                index += 1; space(); if index < bytes.count, bytes[index] == 93 { index += 1; return }
                while true { try value(depth: depth + 1); space(); guard index < bytes.count else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }; if bytes[index] == 93 { index += 1; return }; try take(44) }
            } else if bytes[index] == 34 { _ = try string() }
            else {
                let start = index
                while index < bytes.count && ![9,10,13,32,44,93,125].contains(bytes[index]) { index += 1 }
                guard index > start else { throw CloudWorkspaceSetupOperationRecordError.invalidRecord }
                // Foundation validates primitive spelling after structural preflight.
            }
        }
    }
}
