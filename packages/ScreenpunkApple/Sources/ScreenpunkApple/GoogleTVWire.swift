import Foundation

/// Bounded subset of protobuf used by Android TV Remote v2. TCP reads need not
/// coincide with frame boundaries. Unknown scalar fields are safely skipped.
enum GoogleTVWire {
    static let limit = 64 * 1024
    enum Failure: Error { case malformed, oversized }
    static func varint(_ value: UInt64) -> Data {
        var value = value; var result = Data()
        repeat { let byte = UInt8(value & 127); value >>= 7; result.append(byte | (value == 0 ? 0 : 128)) } while value != 0
        return result
    }
    static func number(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    static func read(_ data: [UInt8], _ index: inout Int) throws -> UInt64? {
        let start = index; var result: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            guard index < data.count else { index = start; return nil }
            let byte = data[index]; index += 1
            if shift == 63 && byte > 1 { throw Failure.malformed }
            result |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return result }
        }
        throw Failure.malformed
    }
    struct Message {
        var numbers: [Int: UInt64] = [:]
        var payloads: [Int: Data] = [:]
        func nested(_ field: Int) throws -> Message { try GoogleTVWire.parse(payloads[field] ?? Data()) }
    }
    static func parse(_ data: Data) throws -> Message {
        guard data.count <= limit else { throw Failure.oversized }
        let data = Array(data); var i = 0; var message = Message()
        while i < data.count {
            guard let tag = try read(data, &i), tag >> 3 > 0, tag >> 3 <= 536870911 else { throw Failure.malformed }
            let field = Int(tag >> 3)
            switch tag & 7 {
            case 0:
                guard let value = try read(data, &i) else { throw Failure.malformed }; message.numbers[field] = value
            case 2:
                guard let length = try read(data, &i), length <= UInt64(data.count - i) else { throw Failure.malformed }
                message.payloads[field] = Data(data[i..<(i + Int(length))]); i += Int(length)
            case 1, 5:
                let count = tag & 7 == 1 ? 8 : 4
                guard i + count <= data.count else { throw Failure.malformed }; i += count
            default: throw Failure.malformed
            }
        }
        return message
    }
    struct Framer {
        private var buffer = Data()
        mutating func append(_ bytes: Data) throws -> [Data] {
            guard buffer.count + bytes.count <= GoogleTVWire.limit * 2 else { throw Failure.oversized }
            buffer.append(bytes); var frames: [Data] = []
            while !buffer.isEmpty {
                var offset = 0
                guard let length = try GoogleTVWire.read(Array(buffer.prefix(10)), &offset) else { break }
                guard length > 0, length <= GoogleTVWire.limit else { throw Failure.oversized }
                guard buffer.count >= offset + Int(length) else { break }
                frames.append(Data(buffer.dropFirst(offset).prefix(Int(length))))
                buffer = Data(buffer.dropFirst(offset + Int(length)))
            }
            return frames
        }
    }
}
