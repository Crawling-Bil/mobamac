import Foundation
import CCommonCrypto

/// Which SSH-1 bulk-data cipher was negotiated for this session. SSH-1
/// advertises a *bitmask* of ciphers a server supports (see
/// `SSH1PublicKeyPacket`); MobaMac only implements the two most commonly
/// offered by real legacy network gear. Blowfish/RC4/IDEA aren't
/// implemented -- if a device only offers those, the connection fails with
/// a clear "no supported cipher" error rather than silently doing nothing.
enum SSH1CipherType: UInt8 {
    case none = 0
    case des = 2
    case des3 = 3
}

/// SSH-1 bulk-data encryption. Two independent chaining states are needed --
/// one for the data this client sends, one for what it receives -- because
/// SSH-1 doesn't reset the CBC IV per packet the way most modern framings
/// do: encryption for a whole direction is one continuous CBC stream from
/// the moment the session key takes effect until the connection closes. So
/// callers must keep one `SSH1Cipher` instance for outgoing traffic and a
/// separate instance (same key, same type) for incoming traffic.
///
/// The 32-byte SSH-1 session key is used differently depending on cipher:
///  - DES: first 8 bytes of the session key are the single DES key.
///  - "3DES" (type 3, `SSH_CIPHER_3DES`): *not* standard 3DES-EDE-CBC.
///    SSH-1 defines this as three independent single-DES-CBC passes, each
///    running over the *entire* stream continuously, using three 8-byte
///    keys sliced from the 32-byte session key (bytes 0..<8, 8..<16,
///    16..<24). Each pass keeps its own CBC chain starting at an all-zero
///    IV. Data is DES-encrypted with key 1, DES-*decrypted* with key 2,
///    then DES-encrypted again with key 3 -- the classic encrypt/decrypt/
///    encrypt (EDE) arrangement, just done as three full CBC passes rather
///    than interleaved block-by-block.
final class SSH1Cipher {
    private let type: SSH1CipherType
    private let key: [UInt8]

    /// One CBC chaining IV per inner single-DES pass (only index 0 is used
    /// for `.des`; all three for `.des3`).
    private var ivs: [[UInt8]]

    init(type: SSH1CipherType, sessionKey: [UInt8]) {
        precondition(sessionKey.count >= 24, "SSH-1 session key must be at least 24 bytes")
        self.type = type
        self.key = sessionKey
        let zeroIV = [UInt8](repeating: 0, count: 8)
        switch type {
        case .none:
            self.ivs = []
        case .des:
            self.ivs = [zeroIV]
        case .des3:
            self.ivs = [zeroIV, zeroIV, zeroIV]
        }
    }

    /// Encrypts `data` (length must be a multiple of 8 bytes -- SSH-1's own
    /// packet padding guarantees this), continuing this instance's chain.
    func encrypt(_ data: [UInt8]) -> [UInt8] {
        switch type {
        case .none:
            return data
        case .des:
            let (out, newIV) = Self.desCBC(data: data, key: Array(key.prefix(8)), iv: ivs[0], encrypt: true)
            ivs[0] = newIV
            return out
        case .des3:
            let k1 = Array(key[0..<8]), k2 = Array(key[8..<16]), k3 = Array(key[16..<24])
            let (s1, iv1) = Self.desCBC(data: data, key: k1, iv: ivs[0], encrypt: true)
            ivs[0] = iv1
            let (s2, iv2) = Self.desCBC(data: s1, key: k2, iv: ivs[1], encrypt: false)
            ivs[1] = iv2
            let (s3, iv3) = Self.desCBC(data: s2, key: k3, iv: ivs[2], encrypt: true)
            ivs[2] = iv3
            return s3
        }
    }

    /// Decrypts `data` (must be a multiple of 8 bytes), continuing this
    /// instance's chain. Must be called with bytes in the exact order they
    /// arrived on the wire -- the CBC chain depends on it.
    func decrypt(_ data: [UInt8]) -> [UInt8] {
        switch type {
        case .none:
            return data
        case .des:
            let (out, newIV) = Self.desCBC(data: data, key: Array(key.prefix(8)), iv: ivs[0], encrypt: false)
            ivs[0] = newIV
            return out
        case .des3:
            // Reverse of encrypt's E(k1) -> D(k2) -> E(k3): decrypting is
            // D(k3) -> E(k2) -> D(k1), each pass still keeping its own
            // independent, continuously-chained IV.
            let k1 = Array(key[0..<8]), k2 = Array(key[8..<16]), k3 = Array(key[16..<24])
            let (s1, iv3) = Self.desCBC(data: data, key: k3, iv: ivs[2], encrypt: false)
            ivs[2] = iv3
            let (s2, iv2) = Self.desCBC(data: s1, key: k2, iv: ivs[1], encrypt: true)
            ivs[1] = iv2
            let (s3, iv1) = Self.desCBC(data: s2, key: k1, iv: ivs[0], encrypt: false)
            ivs[0] = iv1
            return s3
        }
    }

    /// One raw DES-CBC pass via CommonCrypto (no padding -- callers always
    /// supply already block-aligned data). Returns the transformed bytes
    /// plus the IV the *next* call in this chain should use: for
    /// encryption that's the last output ciphertext block; for decryption
    /// it's the last *input* ciphertext block (CBC chains on ciphertext,
    /// not plaintext, in both directions).
    private static func desCBC(data: [UInt8], key: [UInt8], iv: [UInt8], encrypt: Bool) -> (output: [UInt8], nextIV: [UInt8]) {
        guard !data.isEmpty else { return ([], iv) }
        precondition(data.count % 8 == 0, "SSH-1 DES-CBC data must be a multiple of 8 bytes")
        var output = [UInt8](repeating: 0, count: data.count)
        var moved: Int = 0
        let status = CCCrypt(
            CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
            CCAlgorithm(kCCAlgorithmDES),
            CCOptions(0), // no options => CBC mode, no padding (data is always block-aligned already)
            key, key.count,
            iv,
            data, data.count,
            &output, output.count,
            &moved
        )
        precondition(status == kCCSuccess, "CommonCrypto DES-CBC failed with status \(status)")
        let nextIV = encrypt ? Array(output.suffix(8)) : Array(data.suffix(8))
        return (output, nextIV)
    }
}
