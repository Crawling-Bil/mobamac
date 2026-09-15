import Foundation

/// Minimal unsigned arbitrary-precision integer, built only for what SSH-1's
/// RSA session-key encryption needs: construct from/to big-endian bytes, and
/// modular exponentiation. RSA *encryption* (never decryption -- this client
/// only ever uses the server's and host's *public* keys) always uses a small
/// exponent (65537 or 3), so `modPow` doesn't need to be fast for huge
/// exponents, just correct for a handful of squarings. Not a general-purpose
/// bignum: unsigned only, and no division beyond what `modPow` needs
/// internally (binary shift-and-subtract, not schoolbook long division).
struct SSH1BigUInt: Equatable, Comparable {
    /// Little-endian 32-bit limbs. Always normalized: no trailing
    /// (most-significant) zero limbs, except zero itself, which is `[0]`.
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) {
        self.limbs = limbs
        normalize()
    }

    init(_ value: UInt32) {
        self.limbs = [value]
    }

    /// Parses a big-endian byte string -- an mpint's value bytes, or a raw
    /// RSA modulus/exponent -- into a bignum.
    init(bigEndianBytes bytes: [UInt8]) {
        var limbs: [UInt32] = []
        var chunk: UInt32 = 0
        var shift = 0
        for byte in bytes.reversed() {
            chunk |= UInt32(byte) << shift
            shift += 8
            if shift == 32 {
                limbs.append(chunk)
                chunk = 0
                shift = 0
            }
        }
        if shift > 0 {
            limbs.append(chunk)
        }
        self.limbs = limbs.isEmpty ? [0] : limbs
        normalize()
    }

    private mutating func normalize() {
        while limbs.count > 1, limbs.last == 0 {
            limbs.removeLast()
        }
        if limbs.isEmpty { limbs = [0] }
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }

    /// Number of significant bits (0 for zero) -- an SSH-1 mpint's length
    /// prefix is a *bit* count, not a byte count, so this is needed as-is,
    /// not just for sizing byte buffers.
    var bitWidth: Int { Self.bitWidth(of: limbs) }

    /// Minimal big-endian byte representation (no leading zero byte).
    func toBigEndianBytes() -> [UInt8] {
        if isZero { return [0] }
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            bytes.append(UInt8((limb >> 24) & 0xff))
            bytes.append(UInt8((limb >> 16) & 0xff))
            bytes.append(UInt8((limb >> 8) & 0xff))
            bytes.append(UInt8(limb & 0xff))
        }
        while bytes.count > 1, bytes.first == 0 {
            bytes.removeFirst()
        }
        return bytes
    }

    static func == (lhs: SSH1BigUInt, rhs: SSH1BigUInt) -> Bool {
        lhs.limbs == rhs.limbs
    }

    static func < (lhs: SSH1BigUInt, rhs: SSH1BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count {
            return lhs.limbs.count < rhs.limbs.count
        }
        for i in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[i] != rhs.limbs[i] {
            return lhs.limbs[i] < rhs.limbs[i]
        }
        return false
    }

    // MARK: - Internal limb-array arithmetic (used by modPow's inner loop,
    // where wrapping every intermediate value back into an SSH1BigUInt --
    // and paying for normalize() -- would be wasted work).

    private static func trimmed(_ limbs: [UInt32]) -> [UInt32] {
        var l = limbs
        while l.count > 1, l.last == 0 { l.removeLast() }
        return l
    }

    private static func bitWidth(of limbs: [UInt32]) -> Int {
        let t = trimmed(limbs)
        if t.count == 1, t[0] == 0 { return 0 }
        let top = t.last!
        return (t.count - 1) * 32 + (32 - top.leadingZeroBitCount)
    }

    private static func bit(of limbs: [UInt32], at index: Int) -> Bool {
        let limbIndex = index / 32
        let bitIndex = index % 32
        guard limbIndex < limbs.count else { return false }
        return (limbs[limbIndex] >> bitIndex) & 1 == 1
    }

    private static func greaterOrEqual(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        let ac = trimmed(a)
        let bc = trimmed(b)
        if ac.count != bc.count { return ac.count > bc.count }
        for i in stride(from: ac.count - 1, through: 0, by: -1) where ac[i] != bc[i] {
            return ac[i] > bc[i]
        }
        return true
    }

    /// a - b, assuming a >= b (every call site here checks that first).
    private static func subtracting(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(a.count)
        var borrow: Int64 = 0
        for i in 0..<a.count {
            let bVal = i < b.count ? Int64(b[i]) : 0
            var diff = Int64(a[i]) - bVal - borrow
            if diff < 0 {
                diff += 0x1_0000_0000
                borrow = 1
            } else {
                borrow = 0
            }
            result.append(UInt32(diff))
        }
        return trimmed(result)
    }

    private static func shiftLeftOne(_ limbs: [UInt32]) -> [UInt32] {
        var result = limbs
        var carry: UInt32 = 0
        for i in 0..<result.count {
            let newCarry = result[i] >> 31
            result[i] = (result[i] << 1) | carry
            carry = newCarry
        }
        if carry != 0 {
            result.append(carry)
        }
        return trimmed(result)
    }

    private static func addingOne(_ limbs: [UInt32]) -> [UInt32] {
        var result = limbs
        var carry: UInt64 = 1
        var i = 0
        while carry > 0 {
            if i == result.count { result.append(0) }
            let sum = UInt64(result[i]) + carry
            result[i] = UInt32(sum & 0xFFFF_FFFF)
            carry = sum >> 32
            i += 1
        }
        return result
    }

    /// Full-precision multiply.
    private static func multiply(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var result = [UInt32](repeating: 0, count: a.count + b.count)
        for i in 0..<a.count where a[i] != 0 {
            var carry: UInt64 = 0
            let ai = UInt64(a[i])
            for j in 0..<b.count {
                let product = ai * UInt64(b[j]) + UInt64(result[i + j]) + carry
                result[i + j] = UInt32(product & 0xFFFF_FFFF)
                carry = product >> 32
            }
            var k = i + b.count
            while carry > 0 {
                let sum = UInt64(result[k]) + carry
                result[k] = UInt32(sum & 0xFFFF_FFFF)
                carry = sum >> 32
                k += 1
            }
        }
        return trimmed(result)
    }

    /// a mod m, via binary shift-and-subtract long division. O(bits(a) *
    /// bits(m)/32) -- fine for the sizes and call counts RSA public-key
    /// operations need here (a couple of ~2048-bit reductions per squaring,
    /// a few dozen squarings total per connection).
    private static func mod(_ a: [UInt32], _ m: [UInt32]) -> [UInt32] {
        let mTrimmed = trimmed(m)
        let aTrimmed = trimmed(a)
        var remainder: [UInt32] = [0]
        let totalBits = bitWidth(of: aTrimmed)
        guard totalBits > 0 else { return [0] }
        for bitIndex in stride(from: totalBits - 1, through: 0, by: -1) {
            remainder = shiftLeftOne(remainder)
            if bit(of: aTrimmed, at: bitIndex) {
                remainder = addingOne(remainder)
            }
            if greaterOrEqual(remainder, mTrimmed) {
                remainder = subtracting(remainder, mTrimmed)
            }
        }
        return trimmed(remainder)
    }

    /// base^exponent mod modulus, via left-to-right square-and-multiply.
    static func modPow(base: SSH1BigUInt, exponent: SSH1BigUInt, modulus: SSH1BigUInt) -> SSH1BigUInt {
        guard !modulus.isZero else { return SSH1BigUInt(0) }
        var result: [UInt32] = [1]
        let baseLimbs = mod(base.limbs, modulus.limbs)
        let expBits = bitWidth(of: exponent.limbs)
        for bitIndex in stride(from: expBits - 1, through: 0, by: -1) {
            result = mod(multiply(result, result), modulus.limbs)
            if bit(of: exponent.limbs, at: bitIndex) {
                result = mod(multiply(result, baseLimbs), modulus.limbs)
            }
        }
        return SSH1BigUInt(limbs: result)
    }
}
