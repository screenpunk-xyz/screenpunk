import Foundation

/// Private streaming SHA-256: NIST FIPS 180-4 §§4.1.2, 4.2.2, 5.1.1, 6.2.
/// This implementation makes no certification claim and has no fallback digest.
struct NativeJournalSHA256 {
    enum Failure: Error { case lengthOverflow }
    private var state: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2]
    mutating func update<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
        guard UInt64(bytes.count) <= UInt64.max / 8 - length else { throw Failure.lengthOverflow }
        length += UInt64(bytes.count)
        for byte in bytes {
            pending.append(byte)
            if pending.count == 64 { compress(pending); pending.removeAll(keepingCapacity: true) }
        }
    }
    func finalized() -> [UInt8] {
        var copy = self
        let bits = length * 8
        copy.pending.append(0x80)
        while copy.pending.count % 64 != 56 { copy.pending.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { copy.pending.append(UInt8(truncatingIfNeeded: bits >> shift)) }
        for offset in stride(from: 0, to: copy.pending.count, by: 64) { copy.compress(Array(copy.pending[offset..<offset+64])) }
        return copy.state.flatMap { word in [UInt8(truncatingIfNeeded: word >> 24), UInt8(truncatingIfNeeded: word >> 16), UInt8(truncatingIfNeeded: word >> 8), UInt8(truncatingIfNeeded: word)] }
    }
    private func rotate(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32-n)) }
    private mutating func compress(_ block: [UInt8]) {
        var w = [UInt32](repeating: 0, count: 64)
        for i in 0..<16 { let j = i*4; w[i] = UInt32(block[j]) << 24 | UInt32(block[j+1]) << 16 | UInt32(block[j+2]) << 8 | UInt32(block[j+3]) }
        for i in 16..<64 {
            let x=w[i-15], y=w[i-2]
            w[i] = w[i-16] &+ (rotate(x,7) ^ rotate(x,18) ^ (x >> 3)) &+ w[i-7] &+ (rotate(y,17) ^ rotate(y,19) ^ (y >> 10))
        }
        var a=state[0], b=state[1], c=state[2], d=state[3], e=state[4], f=state[5], g=state[6], h=state[7]
        for i in 0..<64 {
            let t1 = h &+ (rotate(e,6) ^ rotate(e,11) ^ rotate(e,25)) &+ ((e & f) ^ (~e & g)) &+ Self.constants[i] &+ w[i]
            let t2 = (rotate(a,2) ^ rotate(a,13) ^ rotate(a,22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            h=g; g=f; f=e; e=d &+ t1; d=c; c=b; b=a; a=t1 &+ t2
        }
        for (i, value) in [a,b,c,d,e,f,g,h].enumerated() { state[i] = state[i] &+ value }
    }
}
