/// Lowercase ASCII formatting for already-computed public package digest bytes.
/// This performs no hashing and admits only unsigned byte values.
enum DevicePublicDigestHex {
    private static let digits = Array("0123456789abcdef".utf8)

    static func encode(_ bytes: [UInt8]) -> String {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count * 2)
        for byte in bytes {
            output.append(digits[Int(byte >> 4)])
            output.append(digits[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
