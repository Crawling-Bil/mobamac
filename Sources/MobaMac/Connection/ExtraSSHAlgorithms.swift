import Foundation
import NIO
import NIOSSH
import Crypto
import Citadel
import BigInt
import CCommonCrypto

/// The SSH algorithms MobaMac offers on top of what NIOSSH and Citadel
/// bring, for network devices that would otherwise share nothing with it.
///
/// Two kinds of device fail without these. Old ones, whose firmware stops
/// at diffie-hellman-group1-sha1 and CBC ciphers, and hardened ones, which
/// turned off everything below aes256 or demand diffie-hellman-group16.
/// (RSA host keys signed with SHA-2 are handled in the vendored NIOSSH,
/// because verifying a host key happens inside it.)
///
/// Everything here is appended after the algorithms already offered, so a
/// device that connected before negotiates exactly what it did before.
/// These are only ever reached when nothing stronger is in common.
enum ExtraSSHAlgorithms {
    static let transportProtectionSchemes: [NIOSSHTransportProtection.Type] = [
        CommonCryptoTransport<AES256CTRSpec>.self,
        CommonCryptoTransport<AES192CTRSpec>.self,
        // Also aes128-ctr, after Citadel's own: Citadel's handles the plain
        // MACs as before, this one is what takes the ETM MACs it lacks.
        CommonCryptoTransport<AES128CTRSpec>.self,
        CommonCryptoTransport<AES256CBCSpec>.self,
        CommonCryptoTransport<AES192CBCSpec>.self,
        CommonCryptoTransport<AES128CBCSpec>.self,
        CommonCryptoTransport<TripleDESCBCSpec>.self,
    ]

    static let keyExchangeAlgorithms: [NIOSSHKeyExchangeAlgorithmProtocol.Type] = [
        ModPDiffieHellman<DHGroup16SHA512>.self,
        ModPDiffieHellman<DHGroup1SHA1>.self,
    ]
}

extension SSHAlgorithms {
    /// Citadel's `.all` (ssh-rsa host keys, aes128-ctr, diffie-hellman-group14
    /// with SHA-1 and SHA-256) plus `ExtraSSHAlgorithms`, in that order.
    static var mobaMac: SSHAlgorithms {
        var algorithms = SSHAlgorithms.all
        let citadelSchemes: [NIOSSHTransportProtection.Type] = [AES128CTR.self]
        let citadelExchanges: [NIOSSHKeyExchangeAlgorithmProtocol.Type] = [
            DiffieHellmanGroup14Sha1.self,
            DiffieHellmanGroup14Sha256.self,
        ]
        algorithms.transportProtectionSchemes = .add(citadelSchemes + ExtraSSHAlgorithms.transportProtectionSchemes)
        algorithms.keyExchangeAlgorithms = .add(citadelExchanges + ExtraSSHAlgorithms.keyExchangeAlgorithms)
        return algorithms
    }
}

enum ExtraSSHAlgorithmError: LocalizedError {
    case unsupportedMAC(String)
    case invalidKeySize
    case cipherFailed
    case invalidPacket
    case macMismatch
    case invalidServerPublicValue
    case invalidHostKeySignature
    case serverRoleUnsupported

    var errorDescription: String? {
        switch self {
        case .unsupportedMAC(let name):
            return "The device chose a MAC MobaMac can't use with this cipher (\(name))."
        case .invalidKeySize:
            return "The SSH key exchange produced keys of the wrong size for the negotiated cipher."
        case .cipherFailed:
            return "Encrypting or decrypting SSH traffic failed."
        case .invalidPacket:
            return "The device sent an SSH packet that could not be read."
        case .macMismatch:
            return "An SSH packet from the device failed its integrity check. Something on the path may be altering the traffic."
        case .invalidServerPublicValue:
            return "The device sent an invalid Diffie-Hellman value during the key exchange."
        case .invalidHostKeySignature:
            return "The device's host key signature didn't verify during the key exchange. Something may be intercepting the connection."
        case .serverRoleUnsupported:
            return "MobaMac can only act as an SSH client."
        }
    }
}

// MARK: - MACs

/// The MACs the CommonCrypto ciphers accept, most preferred first.
///
/// The "-etm@openssh.com" forms (encrypt-then-MAC) use the same HMACs over
/// a different part of the packet. They matter beyond the ciphers here:
/// current switch firmware often offers nothing else, and some SSH servers
/// insist on a MAC in common even when AES-GCM, which ignores the MAC, is
/// the cipher agreed. Offering them gives such a server its match.
enum SSHMac {
    case sha256
    case sha512
    case sha1

    static let etmSuffix = "-etm@openssh.com"

    static let names = [
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512-etm@openssh.com",
        "hmac-sha2-256",
        "hmac-sha2-512",
        "hmac-sha1",
    ]

    init?(name: String?) {
        switch name {
        case "hmac-sha2-256", "hmac-sha2-256-etm@openssh.com": self = .sha256
        case "hmac-sha2-512", "hmac-sha2-512-etm@openssh.com": self = .sha512
        case "hmac-sha1": self = .sha1
        default: return nil
        }
    }

    static func isEncryptThenMAC(_ name: String?) -> Bool {
        name?.hasSuffix(self.etmSuffix) ?? false
    }

    /// Key length and tag length, which are the same for these three.
    var length: Int {
        switch self {
        case .sha256: return SHA256.byteCount
        case .sha512: return SHA512.byteCount
        case .sha1: return Insecure.SHA1.byteCount
        }
    }

    /// MAC = HMAC(key, uint32 sequence_number || unencrypted_packet).
    func authenticate(sequenceNumber: UInt32, packet: [UInt8], key: SymmetricKey) -> [UInt8] {
        switch self {
        case .sha256: return Self.hmac(SHA256.self, sequenceNumber, packet, key)
        case .sha512: return Self.hmac(SHA512.self, sequenceNumber, packet, key)
        case .sha1: return Self.hmac(Insecure.SHA1.self, sequenceNumber, packet, key)
        }
    }

    private static func hmac<H: HashFunction>(_: H.Type, _ sequenceNumber: UInt32, _ packet: [UInt8], _ key: SymmetricKey) -> [UInt8] {
        var hmac = HMAC<H>(key: key)
        hmac.update(data: withUnsafeBytes(of: sequenceNumber.bigEndian) { Array($0) })
        hmac.update(data: packet)
        return hmac.finalize().withUnsafeBytes { Array($0) }
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for index in a.indices {
            difference |= a[index] ^ b[index]
        }
        return difference == 0
    }
}

// MARK: - Ciphers

protocol SSHBlockCipherSpec {
    static var name: String { get }
    static var algorithm: CCAlgorithm { get }
    static var mode: CCMode { get }
    static var keySize: Int { get }
    static var blockSize: Int { get }
}

enum AES256CTRSpec: SSHBlockCipherSpec {
    static let name = "aes256-ctr"
    static let algorithm = CCAlgorithm(kCCAlgorithmAES)
    static let mode = CCMode(kCCModeCTR)
    static let keySize = 32
    static let blockSize = 16
}

enum AES128CTRSpec: SSHBlockCipherSpec {
    static let name = "aes128-ctr"
    static let algorithm = CCAlgorithm(kCCAlgorithmAES)
    static let mode = CCMode(kCCModeCTR)
    static let keySize = 16
    static let blockSize = 16
}

enum AES192CTRSpec: SSHBlockCipherSpec {
    static let name = "aes192-ctr"
    static let algorithm = CCAlgorithm(kCCAlgorithmAES)
    static let mode = CCMode(kCCModeCTR)
    static let keySize = 24
    static let blockSize = 16
}

enum AES256CBCSpec: SSHBlockCipherSpec {
    static let name = "aes256-cbc"
    static let algorithm = CCAlgorithm(kCCAlgorithmAES)
    static let mode = CCMode(kCCModeCBC)
    static let keySize = 32
    static let blockSize = 16
}

enum AES192CBCSpec: SSHBlockCipherSpec {
    static let name = "aes192-cbc"
    static let algorithm = CCAlgorithm(kCCAlgorithmAES)
    static let mode = CCMode(kCCModeCBC)
    static let keySize = 24
    static let blockSize = 16
}

enum AES128CBCSpec: SSHBlockCipherSpec {
    static let name = "aes128-cbc"
    static let algorithm = CCAlgorithm(kCCAlgorithmAES)
    static let mode = CCMode(kCCModeCBC)
    static let keySize = 16
    static let blockSize = 16
}

enum TripleDESCBCSpec: SSHBlockCipherSpec {
    static let name = "3des-cbc"
    static let algorithm = CCAlgorithm(kCCAlgorithm3DES)
    static let mode = CCMode(kCCModeCBC)
    static let keySize = 24
    static let blockSize = 8
}

/// A block cipher with an HMAC, done with CommonCrypto, so CTR and CBC
/// both keep their running state from one packet to the next inside the
/// cryptor, as SSH requires.
///
/// Two framings, picked by the MAC name. Plain MACs are encrypt-and-MAC
/// (RFC 4253 section 6): the whole packet, length included, is encrypted,
/// and the MAC covers the plaintext. The "-etm@openssh.com" MACs are
/// encrypt-then-MAC: the length stays in the clear, everything after it is
/// encrypted, and the MAC covers the length and the ciphertext.
final class CommonCryptoTransport<Spec: SSHBlockCipherSpec>: NIOSSHTransportProtection {
    static var cipherName: String { Spec.name }
    static var macNames: [String] { SSHMac.names }
    static var cipherBlockSize: Int { Spec.blockSize }

    static func keySizes(forMac mac: String?) throws -> ExpectedKeySizes {
        guard let mac = SSHMac(name: mac) else {
            throw ExtraSSHAlgorithmError.unsupportedMAC(mac ?? "none")
        }
        return ExpectedKeySizes(ivSize: Spec.blockSize, encryptionKeySize: Spec.keySize, macKeySize: mac.length)
    }

    var macBytes: Int { self.mac.length }

    private let mac: SSHMac
    private let encryptThenMAC: Bool
    private var encryptor: CCCryptorRef?
    private var decryptor: CCCryptorRef?
    private var outboundMACKey: SymmetricKey
    private var inboundMACKey: SymmetricKey

    init(initialKeys: NIOSSHSessionKeys, mac name: String?) throws {
        guard let mac = SSHMac(name: name) else {
            throw ExtraSSHAlgorithmError.unsupportedMAC(name ?? "none")
        }
        self.mac = mac
        self.encryptThenMAC = SSHMac.isEncryptThenMAC(name)
        self.outboundMACKey = initialKeys.outboundMACKey
        self.inboundMACKey = initialKeys.inboundMACKey
        try self.install(initialKeys)
    }

    deinit {
        self.releaseCryptors()
    }

    func updateKeys(_ newKeys: NIOSSHSessionKeys) throws {
        try self.install(newKeys)
    }

    private func install(_ keys: NIOSSHSessionKeys) throws {
        let encryptor = try Self.makeCryptor(encrypt: true, key: keys.outboundEncryptionKey, iv: keys.initialOutboundIV)
        let decryptor: CCCryptorRef
        do {
            decryptor = try Self.makeCryptor(encrypt: false, key: keys.inboundEncryptionKey, iv: keys.initialInboundIV)
        } catch {
            CCCryptorRelease(encryptor)
            throw error
        }
        self.releaseCryptors()
        self.encryptor = encryptor
        self.decryptor = decryptor
        self.outboundMACKey = keys.outboundMACKey
        self.inboundMACKey = keys.inboundMACKey
    }

    private func releaseCryptors() {
        if let encryptor { CCCryptorRelease(encryptor) }
        if let decryptor { CCCryptorRelease(decryptor) }
        self.encryptor = nil
        self.decryptor = nil
    }

    private static func makeCryptor(encrypt: Bool, key: SymmetricKey, iv: [UInt8]) throws -> CCCryptorRef {
        guard key.bitCount == Spec.keySize * 8, iv.count >= Spec.blockSize else {
            throw ExtraSSHAlgorithmError.invalidKeySize
        }
        // 0x0002 is kCCModeOptionCTR_BE: SSH's counter is big-endian.
        let options = Spec.mode == CCMode(kCCModeCTR) ? CCModeOptions(0x0002) : CCModeOptions(0)
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                    Spec.mode,
                    Spec.algorithm,
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    Spec.keySize,
                    nil,
                    0,
                    0,
                    options,
                    &cryptor
                )
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), let cryptor else {
            throw ExtraSSHAlgorithmError.cipherFailed
        }
        return cryptor
    }

    /// Runs whole blocks through a cryptor. Without padding CommonCrypto
    /// returns every byte it is given at once; anything else is an error
    /// rather than a silently shortened packet.
    private func run(_ cryptor: CCCryptorRef?, _ input: [UInt8]) throws -> [UInt8] {
        guard let cryptor else { throw ExtraSSHAlgorithmError.cipherFailed }
        guard !input.isEmpty else { return [] }
        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, inBytes.count, outBytes.baseAddress, outBytes.count, &moved)
            }
        }
        guard status == CCCryptorStatus(kCCSuccess), moved == input.count else {
            throw ExtraSSHAlgorithmError.cipherFailed
        }
        return output
    }

    func decryptFirstBlock(_ source: inout ByteBuffer) throws {
        // Encrypt-then-MAC leaves the length in the clear: nothing to do.
        if self.encryptThenMAC { return }
        guard let first = source.getBytes(at: source.readerIndex, length: Spec.blockSize) else {
            throw ExtraSSHAlgorithmError.invalidPacket
        }
        let plain = try self.run(self.decryptor, first)
        source.setBytes(plain, at: source.readerIndex)
    }

    func decryptAndVerifyRemainingPacket(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        if self.encryptThenMAC {
            return try self.decryptEncryptThenMAC(&source, sequenceNumber: sequenceNumber)
        }
        let blockSize = Spec.blockSize
        let macLength = self.mac.length
        // The first block was decrypted in place by `decryptFirstBlock`.
        guard
            source.readableBytes >= blockSize + macLength,
            let first = source.readBytes(length: blockSize),
            let ciphertext = source.readBytes(length: source.readableBytes - macLength),
            let receivedMAC = source.readBytes(length: macLength),
            ciphertext.count % blockSize == 0
        else {
            throw ExtraSSHAlgorithmError.invalidPacket
        }

        let packet = first + (try self.run(self.decryptor, ciphertext))
        let expectedMAC = self.mac.authenticate(sequenceNumber: sequenceNumber, packet: packet, key: self.inboundMACKey)
        guard SSHMac.constantTimeEqual(expectedMAC, receivedMAC) else {
            throw ExtraSSHAlgorithmError.macMismatch
        }

        // uint32 packet_length, byte padding_length, payload, padding.
        guard packet.count >= 5 else { throw ExtraSSHAlgorithmError.invalidPacket }
        let paddingLength = Int(packet[4])
        let payloadEnd = packet.count - paddingLength
        guard payloadEnd >= 5 else { throw ExtraSSHAlgorithmError.invalidPacket }
        return ByteBuffer(bytes: packet[5..<payloadEnd])
    }

    /// uint32 length (clear) || encrypted(padding length, payload, padding) || MAC,
    /// where MAC = HMAC(sequence number || length || ciphertext). The MAC is
    /// checked before anything is decrypted.
    private func decryptEncryptThenMAC(_ source: inout ByteBuffer, sequenceNumber: UInt32) throws -> ByteBuffer {
        let macLength = self.mac.length
        guard
            source.readableBytes >= 4 + Spec.blockSize + macLength,
            let lengthBytes = source.readBytes(length: 4),
            let ciphertext = source.readBytes(length: source.readableBytes - macLength),
            let receivedMAC = source.readBytes(length: macLength),
            ciphertext.count % Spec.blockSize == 0
        else {
            throw ExtraSSHAlgorithmError.invalidPacket
        }

        let expectedMAC = self.mac.authenticate(sequenceNumber: sequenceNumber, packet: lengthBytes + ciphertext, key: self.inboundMACKey)
        guard SSHMac.constantTimeEqual(expectedMAC, receivedMAC) else {
            throw ExtraSSHAlgorithmError.macMismatch
        }

        // byte padding_length, payload, padding.
        let body = try self.run(self.decryptor, ciphertext)
        guard let paddingByte = body.first else { throw ExtraSSHAlgorithmError.invalidPacket }
        let payloadEnd = body.count - Int(paddingByte)
        guard payloadEnd >= 1 else { throw ExtraSSHAlgorithmError.invalidPacket }
        return ByteBuffer(bytes: body[1..<payloadEnd])
    }

    func encryptPacket(_ packet: NIOSSHEncryptablePayload, to outboundBuffer: inout ByteBuffer, sequenceNumber: UInt32) throws {
        if self.encryptThenMAC {
            try self.encryptEncryptThenMAC(packet, to: &outboundBuffer, sequenceNumber: sequenceNumber)
            return
        }
        // RFC 4253 section 6: length || padding length || payload || padding
        // must be a multiple of the block size (at least 8) and at least 16
        // bytes, with 4 to 255 bytes of random padding.
        let alignment = max(Spec.blockSize, 8)
        let start = outboundBuffer.writerIndex
        outboundBuffer.writeInteger(UInt32(0))
        outboundBuffer.writeInteger(UInt8(0))
        let payloadLength = outboundBuffer.writeEncryptablePayload(packet)

        var paddingLength = alignment - ((5 + payloadLength) % alignment)
        if paddingLength < 4 { paddingLength += alignment }
        while 5 + payloadLength + paddingLength < 16 { paddingLength += alignment }
        outboundBuffer.writeSSHPaddingBytes(count: paddingLength)

        let total = 5 + payloadLength + paddingLength
        outboundBuffer.setInteger(UInt32(total - 4), at: start)
        outboundBuffer.setInteger(UInt8(paddingLength), at: start + 4)

        guard let plaintext = outboundBuffer.getBytes(at: start, length: total) else {
            throw ExtraSSHAlgorithmError.invalidPacket
        }
        let tag = self.mac.authenticate(sequenceNumber: sequenceNumber, packet: plaintext, key: self.outboundMACKey)
        let ciphertext = try self.run(self.encryptor, plaintext)
        outboundBuffer.setBytes(ciphertext, at: start)
        outboundBuffer.writeBytes(tag)
    }

    /// Encrypt-then-MAC: what gets aligned to the block size is everything
    /// after the length field, since the length is not encrypted.
    private func encryptEncryptThenMAC(_ packet: NIOSSHEncryptablePayload, to outboundBuffer: inout ByteBuffer, sequenceNumber: UInt32) throws {
        let alignment = max(Spec.blockSize, 8)
        let start = outboundBuffer.writerIndex
        outboundBuffer.writeInteger(UInt32(0))
        outboundBuffer.writeInteger(UInt8(0))
        let payloadLength = outboundBuffer.writeEncryptablePayload(packet)

        var paddingLength = alignment - ((1 + payloadLength) % alignment)
        if paddingLength < 4 { paddingLength += alignment }
        while 5 + payloadLength + paddingLength < 16 { paddingLength += alignment }
        outboundBuffer.writeSSHPaddingBytes(count: paddingLength)

        let encryptedLength = 1 + payloadLength + paddingLength
        outboundBuffer.setInteger(UInt32(encryptedLength), at: start)
        outboundBuffer.setInteger(UInt8(paddingLength), at: start + 4)

        guard
            let lengthBytes = outboundBuffer.getBytes(at: start, length: 4),
            let plaintext = outboundBuffer.getBytes(at: start + 4, length: encryptedLength)
        else {
            throw ExtraSSHAlgorithmError.invalidPacket
        }
        let ciphertext = try self.run(self.encryptor, plaintext)
        outboundBuffer.setBytes(ciphertext, at: start + 4)
        let tag = self.mac.authenticate(sequenceNumber: sequenceNumber, packet: lengthBytes + ciphertext, key: self.outboundMACKey)
        outboundBuffer.writeBytes(tag)
    }
}

// MARK: - Diffie-Hellman over fixed MODP groups

protocol SSHModPGroup {
    associatedtype Hash: HashFunction
    static var name: Substring { get }
    /// The group's prime, in hex. Generator is 2 for every MODP group.
    static var primeHex: String { get }
    /// Size of the random private exponent. Twice the group's security
    /// level is the usual choice.
    static var exponentBits: Int { get }
}

/// RFC 2409 Oakley group 2, 1024 bits. Weak by today's standards, and the
/// last thing MobaMac offers: only a device with nothing better gets it.
enum DHGroup1SHA1: SSHModPGroup {
    typealias Hash = Insecure.SHA1
    static let name: Substring = "diffie-hellman-group1-sha1"
    static let exponentBits = 256
    static let primeHex: String = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
        020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
        4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF
        """.filter { !$0.isWhitespace }
}

/// RFC 3526 group 16, 4096 bits (RFC 8268 names it for SSH).
enum DHGroup16SHA512: SSHModPGroup {
    typealias Hash = SHA512
    static let name: Substring = "diffie-hellman-group16-sha512"
    static let exponentBits = 512
    static let primeHex: String = """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74
        020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437
        4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05
        98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB
        9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B
        E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718
        3995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D04507A33
        A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
        ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864
        D87602733EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E2
        08E24FA074E5AB3143DB5BFCE0FD108E4B82D120A92108011A723C12A787E6D7
        88719A10BDBA5B2699C327186AF4E23C1A946834B6150BDA2583E9CA2AD44CE8
        DBBBC2DB04DE8EF92E8EFC141FBECAA6287C59474E6BC05D99B2964FA090C3A2
        233BA186515BE7ED1F612970CEE2D7AFB81BDD762170481CD0069127D5B05AA9
        93B4EA988D8FDDC186FFB7DC90A6C08F4DF435C934063199FFFFFFFFFFFFFFFF
        """.filter { !$0.isWhitespace }
}

/// diffie-hellman-group*-sha* key exchange, client side (RFC 4253 section 8).
struct ModPDiffieHellman<Group: SSHModPGroup>: NIOSSHKeyExchangeAlgorithmProtocol {
    static var keyExchangeInitMessageId: UInt8 { 30 }
    static var keyExchangeReplyMessageId: UInt8 { 31 }
    static var keyExchangeAlgorithmNames: [Substring] { [Group.name] }

    private let ourRole: SSHConnectionRole
    private let previousSessionIdentifier: ByteBuffer?
    private let prime: BigUInt
    private let privateExponent: BigUInt
    private let publicValue: BigUInt

    init(ourRole: SSHConnectionRole, previousSessionIdentifier: ByteBuffer?) {
        self.ourRole = ourRole
        self.previousSessionIdentifier = previousSessionIdentifier
        let prime = BigUInt(Group.primeHex, radix: 16)!
        let exponent = BigUInt.randomInteger(withExactWidth: Group.exponentBits)
        self.prime = prime
        self.privateExponent = exponent
        self.publicValue = BigUInt(2).power(exponent, modulus: prime)
    }

    func initiateKeyExchangeClientSide(allocator: ByteBufferAllocator) -> ByteBuffer {
        // e, as the body of an mpint. NIOSSH wraps it in the length.
        let bytes = Self.mpintBody(self.publicValue)
        var buffer = allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        return buffer
    }

    mutating func completeKeyExchangeServerSide(
        clientKeyExchangeMessage message: ByteBuffer,
        serverHostKey: NIOSSHPrivateKey,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> (KeyExchangeResult, NIOSSHKeyExchangeServerReply) {
        throw ExtraSSHAlgorithmError.serverRoleUnsupported
    }

    mutating func receiveServerKeyExchangePayload(
        serverKeyExchangeMessage: NIOSSHKeyExchangeServerReply,
        initialExchangeBytes: inout ByteBuffer,
        allocator: ByteBufferAllocator,
        expectedKeySizes: ExpectedKeySizes
    ) throws -> KeyExchangeResult {
        var fBuffer = serverKeyExchangeMessage.publicKey
        let f = BigUInt(Data(fBuffer.readBytes(length: fBuffer.readableBytes) ?? []))
        // 1 < f < p - 1, or the shared secret is trivially predictable.
        guard f > 1, f < self.prime - 1 else {
            throw ExtraSSHAlgorithmError.invalidServerPublicValue
        }
        let sharedSecret = f.power(self.privateExponent, modulus: self.prime)

        // H = HASH(V_C || V_S || I_C || I_S || K_S || e || f || K). NIOSSH
        // has already written the first four.
        var hostKeyBlob = allocator.buffer(capacity: 512)
        _ = serverKeyExchangeMessage.hostKey.write(to: &hostKeyBlob)
        initialExchangeBytes.writeInteger(UInt32(hostKeyBlob.readableBytes))
        initialExchangeBytes.writeBuffer(&hostKeyBlob)
        Self.writeMPInt(self.publicValue, to: &initialExchangeBytes)
        Self.writeMPInt(f, to: &initialExchangeBytes)
        Self.writeMPInt(sharedSecret, to: &initialExchangeBytes)

        let exchangeHash = Group.Hash.hash(data: Data(initialExchangeBytes.readableBytesView))
        guard serverKeyExchangeMessage.hostKey.isValidSignature(serverKeyExchangeMessage.signature, for: exchangeHash) else {
            throw ExtraSSHAlgorithmError.invalidHostKeySignature
        }

        let hashBytes = Array(exchangeHash)
        let sessionID = self.previousSessionIdentifier ?? ByteBuffer(bytes: hashBytes)
        let sessionIDBytes = Array(sessionID.readableBytesView)

        var encodedSecret = ByteBuffer()
        Self.writeMPInt(sharedSecret, to: &encodedSecret)
        let secretBytes = Array(encodedSecret.readableBytesView)

        // RFC 4253 section 7.2: HASH(K || H || letter || session_id),
        // extended with HASH(K || H || key so far) until long enough.
        func derive(_ letter: Character, _ length: Int) -> [UInt8] {
            var key = Array(Group.Hash.hash(data: secretBytes + hashBytes + [letter.asciiValue!] + sessionIDBytes))
            while key.count < length {
                key += Array(Group.Hash.hash(data: secretBytes + hashBytes + key))
            }
            return Array(key.prefix(length))
        }

        guard case .client = self.ourRole else {
            throw ExtraSSHAlgorithmError.serverRoleUnsupported
        }
        let keys = NIOSSHSessionKeys(
            initialInboundIV: derive("B", expectedKeySizes.ivSize),
            initialOutboundIV: derive("A", expectedKeySizes.ivSize),
            inboundEncryptionKey: SymmetricKey(data: derive("D", expectedKeySizes.encryptionKeySize)),
            outboundEncryptionKey: SymmetricKey(data: derive("C", expectedKeySizes.encryptionKeySize)),
            inboundMACKey: SymmetricKey(data: derive("F", expectedKeySizes.macKeySize)),
            outboundMACKey: SymmetricKey(data: derive("E", expectedKeySizes.macKeySize))
        )
        return KeyExchangeResult(sessionID: sessionID, keys: keys)
    }

    /// The bytes of an mpint without its length: big-endian, minimal, with
    /// a leading zero when the top bit is set so it does not read as
    /// negative. Zero is empty.
    static func mpintBody(_ value: BigUInt) -> [UInt8] {
        var bytes = Array(value.serialize())
        while bytes.first == 0 { bytes.removeFirst() }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return bytes
    }

    static func writeMPInt(_ value: BigUInt, to buffer: inout ByteBuffer) {
        let body = self.mpintBody(value)
        buffer.writeInteger(UInt32(body.count))
        buffer.writeBytes(body)
    }
}
