import Foundation

/// The CRC-32 SSH-1 puts at the end of every packet (over `padding + type +
/// data`, computed *before* encryption). This is the standard
/// zlib/PKZip/Ethernet CRC-32 (polynomial 0xEDB88320, reflected, init
/// 0xFFFFFFFF, final XOR 0xFFFFFFFF) -- SSH-1's RFC draft explicitly says to
/// use "the CRC-32 algorithm as used in Ethernet, gzip, etc.", not a
/// bespoke variant, so this is a plain textbook table-driven implementation.
enum SSH1CRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB8_8320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            table[i] = c
        }
        return table
    }()

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The CRC as 4 big-endian bytes, ready to append to a packet.
    static func checksumBytes(_ bytes: [UInt8]) -> [UInt8] {
        let value = checksum(bytes)
        return [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
    }
}
