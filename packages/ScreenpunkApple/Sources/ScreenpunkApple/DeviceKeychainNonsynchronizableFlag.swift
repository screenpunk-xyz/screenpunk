import Foundation

/// Security returns nonsync metadata as Boolean false or exact numeric zero on iOS.
/// Missing legacy metadata keeps the existing nonsync default; all other values fail.
enum DeviceKeychainNonsynchronizableFlag {
    static func matches(_ value: CFTypeRef?) -> Bool {
        guard let value else { return true }
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return !CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
        }
        // Never truncate fractional/nonzero values into an accepted integer zero.
        if CFGetTypeID(value) == CFNumberGetTypeID() {
            return CFNumberCompare(unsafeBitCast(value, to: CFNumber.self), NSNumber(value: 0), nil) == .compareEqualTo
        }
        return false
    }
}
