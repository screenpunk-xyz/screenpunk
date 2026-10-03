import Foundation

/// Bounded ASCII RFC3339 validation. No untrusted precision reaches ICU or floating point.
/// Original wire strings remain unchanged; this internal representation is only for comparison.
enum BoundedRFC3339TimestampFailure: Error { case invalidInput }
struct BoundedRFC3339Instant: Equatable {
    let seconds: Int64
    let fraction: String // trailing zeroes removed; empty means an integral second
}
func boundedRFC3339Time(_ value: String, acceptsLowercaseSeparators: Bool = false) throws -> BoundedRFC3339Instant {
    let bytes = Array(value.utf8.prefix(257))
    guard (20...256).contains(bytes.count) else { throw BoundedRFC3339TimestampFailure.invalidInput }
    func integer(_ start: Int, _ count: Int) throws -> Int {
        guard start >= 0, start + count <= bytes.count else { throw BoundedRFC3339TimestampFailure.invalidInput }
        var result = 0
        for byte in bytes[start..<(start + count)] {
            guard (48...57).contains(byte) else { throw BoundedRFC3339TimestampFailure.invalidInput }
            result = result * 10 + Int(byte - 48)
        }
        return result
    }
    guard bytes[4] == 45, bytes[7] == 45, (bytes[10] == 84 || (acceptsLowercaseSeparators && bytes[10] == 116)),
          bytes[13] == 58, bytes[16] == 58 else { throw BoundedRFC3339TimestampFailure.invalidInput }
    let year = try integer(0, 4), month = try integer(5, 2), day = try integer(8, 2)
    let hour = try integer(11, 2), minute = try integer(14, 2), second = try integer(17, 2)
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    guard year > 0, (1...12).contains(month), day > 0, day <= days[month - 1],
          hour < 24, minute < 60, second < 60 else { throw BoundedRFC3339TimestampFailure.invalidInput }
    var cursor = 19, fraction: [UInt8] = []
    if bytes[cursor] == 46 {
        cursor += 1
        let start = cursor
        while cursor < bytes.count, (48...57).contains(bytes[cursor]) { fraction.append(bytes[cursor]); cursor += 1 }
        guard cursor > start else { throw BoundedRFC3339TimestampFailure.invalidInput }
    }
    guard cursor < bytes.count else { throw BoundedRFC3339TimestampFailure.invalidInput }
    var offset = 0
    if bytes[cursor] == 90 || (acceptsLowercaseSeparators && bytes[cursor] == 122) {
        guard cursor + 1 == bytes.count else { throw BoundedRFC3339TimestampFailure.invalidInput }
    } else {
        guard bytes[cursor] == 43 || bytes[cursor] == 45, cursor + 6 == bytes.count,
              bytes[cursor + 3] == 58 else { throw BoundedRFC3339TimestampFailure.invalidInput }
        let offsetHour = try integer(cursor + 1, 2), offsetMinute = try integer(cursor + 4, 2)
        guard offsetHour < 24, offsetMinute < 60 else { throw BoundedRFC3339TimestampFailure.invalidInput }
        offset = (offsetHour * 60 + offsetMinute) * 60 * (bytes[cursor] == 43 ? 1 : -1)
    }
    while fraction.last == 48 { fraction.removeLast() }
    // Proleptic Gregorian day count relative to 1970-01-01. Four-digit years
    // and bounded offsets keep every intermediate safely inside Int64.
    let priorYears = year - 1
    let priorDays = 365 * priorYears + priorYears / 4 - priorYears / 100 + priorYears / 400
    let dayIndex = priorDays + days.prefix(month - 1).reduce(0, +) + day - 1 - 719162
    let seconds = Int64(dayIndex) * 86400 + Int64(hour * 3600 + minute * 60 + second - offset)
    return BoundedRFC3339Instant(seconds: seconds, fraction: String(decoding: fraction, as: UTF8.self))
}
